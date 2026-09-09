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

/// Static ranges are finite because the entire portal tree shares eight live
/// physical owners. Both the shown and candidate 32-tile cohorts fit the shared
/// 256-MiB accounting pool without pretending GPU copies are free.
struct SceneCompositionPlan: Sendable {
  static let maximumLiveOwners = 8
  static let maximumTiles = 32
  static let maximumPrimitives = 96
  let revision: UInt64
  let workspaceID: UUID
  let rootBoardID: UUID
  let liveOwners: [SceneCompositionLiveOwner]
  let bands: [SceneCompositionBand]
  let coverage: [SceneCompositionPlane: CompositionTileCoverage]
  let presentations: [SceneCompositionPlane: SessionPresence]
  let tiles: [SceneCompositionTileKey]
  var primitiveCount: Int { tiles.count + liveOwners.count + 1 }

  func rank(id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Double? {
    guard let owner = liveOwners.first(where: { $0.id == id && $0.plane == plane }) else { return nil }
    let peers = liveOwners.filter { $0.plane == plane && $0.position.layer == owner.position.layer }.sorted { $0.position < $1.position }
    return peers.firstIndex(of: owner).map { Double($0 * 2 + 1) }
  }
  func allowsLive(_ id: WorkspaceSpatialID, in plane: SceneCompositionPlane) -> Bool { rank(id: id, in: plane) != nil }

  static func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double, previous: Self?) async throws -> Self {
    var pinned = pinned
    if let id = presence.focusedItemID { pinned.insert(.item(id)) }
    guard displayScale.isFinite, displayScale > 0, frame.rootBoardID == presence.boardID else { throw SceneRenderError.resourceLimit }
    // Board ink retains the current Pencil owner even when it is still empty.
    guard pinned.count < maximumLiveOwners else { throw SceneRenderError.snapshotPending("live_owner_budget") }
    var candidates: [(plane: SceneCompositionPlane, id: WorkspaceSpatialID, pinned: Bool)] = []
    let boardIDs = [presence.boardID] + frame.worksets.keys.filter { $0 != presence.boardID }.sorted { $0.uuidString < $1.uuidString }
    for boardID in boardIDs {
      guard let workset = frame.worksets[boardID] else { continue }
      for item in workset.items { candidates.append((.board(boardID), .item(item.id), pinned.contains(.item(item.id)))) }
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
    let protected = Set(candidates.filter(\.pinned).map { "\($0.plane):\($0.id)" })
    while true {
      do {
        return try assemble(revision: source.revision, workspaceID: source.workspaceID, owners: owners, presence: presence,
          frame: frame, pinned: pinned, displayScale: displayScale, previous: previous)
      } catch {
        guard let index = owners.lastIndex(where: { !protected.contains("\($0.plane):\($0.id)") }) else { throw error }
        owners.remove(at: index)
      }
    }
  }

  private static func assemble(revision: UInt64, workspaceID: UUID, owners requestedOwners: [SceneCompositionLiveOwner],
    presence: SessionPresence, frame: WorkspaceSceneFrame, pinned: Set<WorkspaceSpatialID>,
    displayScale: Double, previous: Self?) throws -> Self {
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
    guard pinned.allSatisfy({ pin in owners.contains { $0.id == pin } }) else { throw SceneRenderError.snapshotPending("pinned_owner_projection") }
    for boardID in includedBoards {
      guard let view = frame.presences[boardID] else { throw SceneRenderError.snapshotPending("portal_projection") }
      let plane = SceneCompositionPlane.board(boardID)
      presentations[plane] = view
      let margin = 96.0
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
      let layers: [ScenePaintPosition.Layer] = plane.coverID == nil
        ? (plane.boardID == presence.boardID ? [.elements, .covers] : [.elements, .ink, .covers]) : [.elements]
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
    guard minimumCost.values.reduce(0, +) <= maximumTiles else { throw SceneRenderError.resourceLimit }
    var remaining = maximumTiles
    for (offset, plane) in planes.enumerated() {
      let planeBands = bands.filter { $0.plane == plane }
      let reserved = planes.dropFirst(offset + 1).reduce(0) { $0 + (minimumCost[$1] ?? 0) }
      let allowance = max(1, (remaining - reserved) / max(1, planeBands.count))
      guard let view = presentations[plane], let bounds = bounds[plane], let pixels = density[plane] else { throw SceneRenderError.resourceLimit }
      let cover = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: pixels,
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
    guard tiles.count <= maximumTiles, tiles.count + owners.count + 1 <= maximumPrimitives else { throw SceneRenderError.resourceLimit }
    return .init(revision: revision, workspaceID: workspaceID, rootBoardID: presence.boardID, liveOwners: owners, bands: bands,
      coverage: coverage, presentations: presentations, tiles: tiles)
  }
}

@MainActor
final class SceneCompositionCohort {
  let id = UUID()
  let plan: SceneCompositionPlan
  let frame: WorkspaceSceneFrame
  let liveData: SceneCompositionLiveData
  let rasters: [SceneCompositionTileKey: RasterLease]
  let liveRasters: [SceneCompositionLiveOwner: RasterLease]
  init(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame, liveData: SceneCompositionLiveData,
    rasters: [SceneCompositionTileKey: RasterLease], liveRasters: [SceneCompositionLiveOwner: RasterLease]) {
    self.plan = plan; self.frame = frame; self.liveData = liveData; self.rasters = rasters
    self.liveRasters = liveRasters
  }
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
  private let diskCache: SceneCompositionTileCache?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private var preparingPlan: SceneCompositionPlan?
  @ObservationIgnored private var preparingSources: WorkspaceSceneFrame.SourceIdentity?
  init(resources: SceneRenderResources = .shared, cacheRoot: URL? = nil) {
    self.resources = resources; diskCache = cacheRoot.map { SceneCompositionTileCache(root: $0) }
  }

  func prepare(source: SceneCompositionSource, presence: SessionPresence, frame: WorkspaceSceneFrame,
    pinned: Set<WorkspaceSpatialID>, displayScale: Double = 2,
    permitsPreparation: @escaping @MainActor () -> Bool = { true }) {
    guard !stopped else { return }
    let sources = frame.sourceIdentity
    if let plan = published?.plan, published?.frame.sourceIdentity == sources,
      plan.revision == source.revision, plan.workspaceID == source.workspaceID,
      Self.covers(plan, presence: presence, pinned: pinned) { return }
    if preparingSources == sources, let plan = preparingPlan,
      plan.revision == source.revision, plan.workspaceID == source.workspaceID,
      Self.covers(plan, presence: presence, pinned: pinned) { return }
    task?.cancel(); requestID = UUID()
    let id = requestID
    isPreparing = true; failure = nil; preparingPlan = nil; preparingSources = sources
    task = Task { [weak self, resources] in
      defer { self?.inFlight[id] = nil }
      var rasters: [SceneCompositionTileKey: RasterLease] = [:]
      var liveRasters: [SceneCompositionLiveOwner: RasterLease] = [:]
      do {
        let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
          pinned: pinned, displayScale: displayScale, previous: self?.published?.plan)
        try Task.checkCancellation()
        guard self?.requestID == id, permitsPreparation() else { throw CancellationError() }
        self?.preparingPlan = plan
        let liveData = try await source.liveData(plan: plan, presence: presence, frame: frame)
        let previous = self?.published
        let canCarry: Bool
        if let previous {
          canCarry = try await source.canCarryStaticPixels(from: previous.plan, liveData: previous.liveData,
            to: plan, liveData: liveData)
        } else { canCarry = false }
        let renderer = SceneCompositionRenderer(source: source, resources: resources,
          permitsPreparation: { [weak self] in self?.requestID == id && permitsPreparation() })
        defer { renderer.finishPreparation() }
        liveRasters = try await renderer.prepareLiveRasters(plan: plan, displayScale: displayScale)
        for key in plan.tiles {
          try Task.checkCancellation()
          guard self?.requestID == id, let presentation = plan.presentations[key.plane] else { throw CancellationError() }
          if let raster = resources.retainRaster(for: .composition(key)) { rasters[key] = raster }
          else if canCarry, let previous,
            let old = previous.rasters[key.atRevision(previous.plan.revision)],
            let raster = resources.retainRaster(for: old.source) { rasters[key] = raster }
          else if let raster = try await self?.loadCached(key) { rasters[key] = raster }
          else {
            let raster = try await renderer.renderTile(key: key, presentation: presentation)
            rasters[key] = raster
            await self?.saveCached(raster, key: key)
          }
        }
        try await source.validate(); try Task.checkCancellation()
        guard self?.requestID == id, permitsPreparation(), rasters.count == plan.tiles.count else { throw CancellationError() }
        self?.published = .init(plan: plan, frame: frame, liveData: liveData, rasters: rasters, liveRasters: liveRasters)
        rasters.removeAll(); liveRasters.removeAll()
        self?.isPreparing = false; self?.preparingPlan = nil; self?.preparingSources = nil; self?.task = nil
      } catch {
        for raster in rasters.values { raster.release() }
        for raster in liveRasters.values { raster.release() }
        guard self?.requestID == id else { return }
        self?.isPreparing = false; self?.preparingPlan = nil; self?.preparingSources = nil; self?.task = nil
        if !(error is CancellationError) { self?.failure = String(describing: error) }
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
    removePublishedCoverage()
  }

  private func loadCached(_ key: SceneCompositionTileKey) async throws -> RasterLease? {
    guard let diskCache else { return nil }
    guard let allocation = resources.reserveRaster(pixelWidth: 512, pixelHeight: 512, backingCount: 4) else { throw SceneRenderError.resourceLimit }
    defer { allocation.release() }
    guard let temporary = resources.reserveDerivedBytes(8 * 1_024 * 1_024) else { throw SceneRenderError.resourceLimit }
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
      let temporary = resources.reserveDerivedBytes(8 * 1_024 * 1_024) else { return }
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
struct SceneCompositionTileBandView: View {
  let cohort: SceneCompositionCohort
  let band: SceneCompositionBand
  let presence: SessionPresence
  var body: some View {
    ForEach(cohort.plan.tiles.filter { $0.plane == band.plane && $0.range == band.range }, id: \.self) { key in
      if let raster = cohort.rasters[key], !raster.isReleased {
        let rect = frame(for: key.tile)
        tileImage(raster).resizable().interpolation(.high)
          .frame(width: rect.width, height: rect.height)
          .position(x: rect.midX, y: rect.midY)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
  }
  private func frame(for tile: CompositionTile) -> CGRect {
    if band.plane.coverID != nil {
      let delta = WorldPoint.zero.delta(to: tile.origin)
      return .init(x: delta.x, y: delta.y, width: tile.worldSize, height: tile.worldSize)
    }
    let screen = presence.camera.worldToScreen(tile.origin, viewport: presence.viewport)
    return .init(x: screen.x, y: screen.y, width: tile.worldSize * presence.camera.scale, height: tile.worldSize * presence.camera.scale)
  }
  private func tileImage(_ raster: RasterLease) -> Image {
    #if os(iOS)
      Image(uiImage: raster.image)
    #else
      Image(nsImage: raster.image)
    #endif
  }
}

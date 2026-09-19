import Foundation
import NotebookCore
import Observation
import SwiftUI
import WebKit

enum SceneRasterSource: Equatable, Sendable {
  case agent(AgentElement)
  case agentRegion(AgentElement, PageRect)
  case document(id: UUID, token: String)
  case composition(SceneCompositionTileKey)

  /// A raster belongs to the element's local pixels. Moving those pixels in the
  /// scene does not change their source; size, program and state still do.
  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.agent(let left), .agent(let right)):
      left.id == right.id && left.kind == right.kind
        && left.frame.width == right.frame.width && left.frame.height == right.frame.height
        && left.source == right.source && left.html == right.html
        && left.css == right.css && left.javaScript == right.javaScript && left.programPackage == right.programPackage && left.state == right.state
    case (.agentRegion(let left, let leftRegion), .agentRegion(let right, let rightRegion)):
      Self.agent(left) == .agent(right) && leftRegion == rightRegion
    case (.document(let leftID, let leftToken), .document(let rightID, let rightToken)):
      leftID == rightID && leftToken == rightToken
    case (.composition(let left), .composition(let right)): left.pixelIdentity == right.pixelIdentity
    default: false
    }
  }

  var agentElement: AgentElement? {
    switch self { case .agent(let value), .agentRegion(let value, _): value; default: nil }
  }
  var captureRegion: PageRect? { if case .agentRegion(_, let rect) = self { return rect }; return nil }

  fileprivate var owner: RasterOwner {
    switch self {
    case .agent(let element): .agent(element.id)
    case .agentRegion(let element, _): .agent(element.id)
    case .document(let id, _): .document(id)
    case .composition(let key): .composition(key.pixelIdentity)
    }
  }
}

fileprivate enum RasterOwner: Hashable { case agent(String), document(UUID), composition(SceneCompositionTileKey) }

enum WebPriority: Int, Comparable, Sendable {
  case currentPage, input, liveProgram, neighbor, visible, background
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  /// Visible source preparation and export preparation share the same executor
  /// allowance. Neighbor pages are already live physical sheets, not raster jobs.
  fileprivate var preparesRaster: Bool { self == .visible || self == .background }
  /// A visible control is already an input owner, even before its first tap.
  fileprivate var isPassive: Bool { self > .liveProgram }
}

enum SceneRenderError: Error, Equatable, CustomStringConvertible {
  case resourceLimit
  case snapshotPending(String)
  var description: String {
    switch self {
    case .resourceLimit: "resource_limit"
    case .snapshotPending(let id): "snapshot_pending: \(id)"
    }
  }
}

enum SceneAllocationPriority: Equatable, Sendable { case input, passive }

/// Both apps mount interactive sources. On iPad their native Pencil canvases
/// reserve input backing in this same pool; a headless export has no such owner.
enum SceneResourceProfile: Equatable, Sendable {
  case interactive, headless
}

/// A retained image is charged until its final lease ends. Released leases cannot
/// keep an unaccounted strong image reference alive.
@MainActor
final class RasterLease {
  let source: SceneRasterSource
  let pixelScale: Double
  let accountedByteCount: Int
  let semanticSelection: ProgramSemanticSelection?
  let entryID: UUID
  private var resources: SceneRenderResources?
  private var retainedImage: AgentSnapshotImage?
  private var mipmaps: [CGImage]
  var isReleased: Bool { resources == nil }
  var image: AgentSnapshotImage {
    precondition(!isReleased, "A released raster lease has no image")
    return retainedImage!
  }
  var hasMipmaps: Bool { !mipmaps.isEmpty }
  /// Choose from this entry's admitted pixel pyramid using installed native
  /// geometry. Camera motion never allocates or resamples an image.
  func sampledImage(for pixelSize: CGSize) -> CGImage? {
    precondition(!isReleased, "A released raster lease has no pixels")
    #if os(iOS)
    var result = retainedImage?.cgImage
    #else
    var result = retainedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #endif
    // Never magnify a lower mip when sharper admitted pixels already exist.
    // Thin lines and text must not lose samples merely to select a nearer LOD.
    for level in mipmaps {
      guard Double(level.width) >= pixelSize.width,
        Double(level.height) >= pixelSize.height else { break }
      result = level
    }
    return result
  }
  /// Snapshot composition reads this retained entry, never a newer cache alias.
  func image(for source: SceneRasterSource, minimumScale: Double = 0) -> AgentSnapshotImage? {
    precondition(minimumScale.isFinite && minimumScale >= 0)
    guard !isReleased, self.source == source, pixelScale + 0.000_001 >= minimumScale else { return nil }
    return retainedImage
  }
  fileprivate init(source: SceneRasterSource, pixelScale: Double, image: AgentSnapshotImage,
    mipmaps: [CGImage], byteCount: Int, entryID: UUID, semanticSelection: ProgramSemanticSelection?, resources: SceneRenderResources) {
    self.source = source; self.pixelScale = pixelScale; retainedImage = image; accountedByteCount = byteCount
    self.mipmaps = mipmaps; self.semanticSelection = semanticSelection
    self.entryID = entryID; self.resources = resources
  }
  func retainedCopy() -> RasterLease? {
    resources?.retainRasterEntry(entryID)
  }
  func release() {
    guard let owner = resources else { return }
    resources = nil; retainedImage = nil; mipmaps = []
    owner.releaseRaster(entryID)
  }
  isolated deinit { release() }
}

/// Reserves derived CPU/GPU backing before its allocation. GPU users retain
/// this lease until the last submitted command has completed, not just unmount.
@MainActor
final class RasterReservation {
  fileprivate(set) var byteCount: Int
  fileprivate let id: UUID
  fileprivate weak var resources: SceneRenderResources?
  private(set) var isReleased = false
  fileprivate init(id: UUID, byteCount: Int, resources: SceneRenderResources) {
    self.id = id; self.byteCount = byteCount; self.resources = resources
  }
  func release() {
    guard !isReleased else { return }
    isReleased = true
    resources?.releaseReservation(id)
    resources = nil
  }
  isolated deinit { release() }
}

@MainActor
final class WebSurfaceLease {
  let id: UUID
  private(set) var priority: WebPriority
  private var resources: SceneRenderResources?
  private var releaseRequested = false
  private var borrowers = 0
  var isReleased: Bool { releaseRequested }
  fileprivate init(id: UUID, priority: WebPriority, resources: SceneRenderResources) {
    self.id = id; self.priority = priority; self.resources = resources
  }
  func release() {
    resources?.setIdleWebReclamation(id, reclaim: nil)
    releaseRequested = true
    releaseIfUnborrowed()
  }
  private func releaseIfUnborrowed() {
    guard releaseRequested, borrowers == 0, let owner = resources else { return }
    resources = nil
    owner.releaseWebSurface(id)
  }
  /// Only a quiescent owner may offer its executor. The pool selects one
  /// concrete lease; outstanding physical borrows still delay actual release.
  func offerIdleReclamation(_ reclaim: (@MainActor () -> Void)?) {
    guard !releaseRequested, let resources else { return }
    resources.setIdleWebReclamation(id, reclaim: reclaim)
  }
  /// A checkpoint may refuse retirement. Keep the real slot occupied, but
  /// finish this attempt so another idle owner can satisfy foreground demand.
  func cancelIdleReclamation() {
    guard !releaseRequested else { return }
    resources?.cancelIdleWebReclamation(id)
  }
  /// Submitted source preparation may outlive its physical mount. Its callback
  /// returns this borrow before another WebKit may consume the same slot.
  func borrow() throws -> WebSurfaceBorrow {
    guard !releaseRequested, resources != nil else { throw CancellationError() }
    borrowers += 1
    return WebSurfaceBorrow(self)
  }
  fileprivate func returnBorrow() {
    precondition(borrowers > 0)
    borrowers -= 1
    releaseIfUnborrowed()
  }
  /// A page curl transfers the already mounted owner between current and
  /// neighbor roles. Reclassification never replaces or revokes its WebKit.
  func updatePriority(_ priority: WebPriority) {
    guard !releaseRequested, let resources, self.priority != priority else { return }
    self.priority = priority
    resources.updateWebPriority(id, priority: priority)
  }
  isolated deinit { release() }
}

@MainActor
final class WebSurfaceBorrow {
  private var lease: WebSurfaceLease?
  fileprivate init(_ lease: WebSurfaceLease) { self.lease = lease }
  func release() {
    let owner = lease; lease = nil
    owner?.returnBorrow()
  }
  isolated deinit { release() }
}

/// A portal's cover and the ink of the board seen through it are different
/// physical owners. Element IDs are local to their physical source plane.
enum ScenePhysicalOwner: Hashable {
  case boardInk(UUID)
  case item(UUID)
  case element(boardID: UUID, coverID: UUID?, id: String)
}

@MainActor
final class ScenePhysicalOwnerLease {
  let owners: Set<ScenePhysicalOwner>
  fileprivate var resources: SceneRenderResources?
  var isReleased: Bool { resources == nil }
  var allocationPriority: SceneAllocationPriority {
    guard owners.count == 1, let id = owners.first else { return .passive }
    return resources?.physicalPriority(for: id) ?? .passive
  }
  fileprivate init(owners: Set<ScenePhysicalOwner>, resources: SceneRenderResources) {
    self.owners = owners; self.resources = resources
  }
  func release() {
    let owner = resources; resources = nil
    owner?.releasePhysicalOwners(owners)
  }
  isolated deinit { release() }
}

/// A read of the existing pool, not a reservation or a second quota. Held
/// entries cannot be evicted; temporary allocations remain charged separately.
struct SceneRasterAdmission: Sendable, Equatable {
  let pinnedBytes: Int
  let reservedBytes: Int
  let pinnedCount: Int
  let reservedCount: Int
  let byteLimit: Int
  let countLimit: Int
  let passiveReservedBytes: Int
  let passiveByteLimit: Int
  var heldBytes: Int { pinnedBytes + reservedBytes }
  func fits(additionalBytes: Int, additionalCount: Int) -> Bool {
    additionalBytes >= 0 && additionalCount >= 0
      && additionalBytes <= byteLimit - heldBytes
      && additionalBytes <= passiveByteLimit - pinnedBytes - passiveReservedBytes
      && additionalCount <= countLimit - pinnedCount - reservedCount
  }
}

struct SceneRasterRefusal: Sendable, Equatable {
  let generation: UInt64
  let requestedBytes: Int
  let requestedCount: Int
  let admission: SceneRasterAdmission
}

/// An owner offers only disposable state. A returned task is the real release
/// boundary (for example a WebKit callback), not permission to reuse its bytes.
@MainActor
struct SceneResourceReclamationCandidate {
  enum Value: Int { case unused, neighbour, canonicalLayout }
  let id: UUID
  let bytes: Int
  let rasterCount: Int
  let value: Value
  let distance: Int
  let restorationMilliseconds: Double
  let release: @MainActor () -> Task<Void, Never>?
}

@MainActor
enum SceneResourceReclamationPlanner {
  static func next(_ candidates: [SceneResourceReclamationCandidate], bytes: Int, count: Int)
    -> SceneResourceReclamationCandidate? {
    candidates.filter { $0.bytes > 0 || (count > 0 && $0.rasterCount > 0) }.min {
      if $0.value != $1.value { return $0.value.rawValue < $1.value.rawValue }
      if $0.distance != $1.distance { return $0.distance > $1.distance }
      let left = $0.restorationMilliseconds / Double(max(1, min($0.bytes, max(1, bytes))))
      let right = $1.restorationMilliseconds / Double(max(1, min($1.bytes, max(1, bytes))))
      if left != right { return left < right }
      if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
      return $0.id.uuidString < $1.id.uuidString
    }
  }
}

/// One admission owner for derived rasters and WebKit execution. Content and
/// interactive state remain in their existing documents; this store is disposable.
@MainActor
@Observable
final class SceneRenderResources {
  static let shared = SceneRenderResources()
  static let didChange = Notification.Name("NotebookSceneRenderResourcesDidChange")
  static let didGainRasterAdmission = Notification.Name("NotebookSceneRenderResourcesDidGainRasterAdmission")
  let byteLimit: Int
  let profile: SceneResourceProfile
  let passiveByteLimit: Int
  let maximumWebSurfaces: Int
  let maximumBackgroundWebSurfaces: Int
  let maximumPendingWebRequests: Int
  let reservedInteractiveSlots: Int
  private let maximumRasterCount: Int
  private let diagnosticCapacity: Int
  private(set) var residentBytes = 0
  private(set) var reservedBytes = 0
  private(set) var passiveReservedBytes = 0
  @ObservationIgnored private(set) var peakAccountedBytes = 0
  private(set) var rasterCount = 0
  private(set) var activeWebSurfaceCount = 0
  /// All raster-only executors, including visible work promoted ahead of export.
  private(set) var activeBackgroundWebSurfaceCount = 0
  private(set) var activePassiveWebSurfaceCount = 0
  private(set) var pendingWebRequestCount = 0
  /// Changes only when web admission gains a queue position or usable slot.
  /// A view whose queue request was refused can retry on this epoch; raster
  /// eviction and snapshot completion never create a web retry signal.
  private(set) var webAdmissionGeneration: UInt64 = 0
  private(set) var rasterGeneration: UInt64 = 0
  private(set) var rasterAdmissionGeneration: UInt64 = 0
  @ObservationIgnored private var admissionNotification: Task<Void, Never>?
  @ObservationIgnored private var reclamationOwners: [UUID: @MainActor () -> [SceneResourceReclamationCandidate]] = [:]
  @ObservationIgnored private var pendingReclamations: Set<UUID> = []
  @ObservationIgnored private var reclamationNotification: Task<Void, Never>?
  var pendingReclamationCount: Int { pendingReclamations.count }
  @ObservationIgnored private var isReclaimingIdleResources = false
  @ObservationIgnored weak var documentShellPreparation: DocumentShellPreparation?
  @ObservationIgnored private var isReclaimingIdleWeb = false
  private struct IdleWebSurface {
    let order: UInt64
    let reclaim: @MainActor () -> Void
  }
  @ObservationIgnored private var idleWebSurfaces: [UUID: IdleWebSurface] = [:]
  @ObservationIgnored private var retiringIdleWebSurfaces: Set<UUID> = []

  fileprivate func setIdleWebReclamation(_ id: UUID, reclaim: (@MainActor () -> Void)?) {
    guard activeWebSurfaces[id] != nil else { return }
    if let reclaim {
      waiterClock &+= 1
      idleWebSurfaces[id] = .init(order: waiterClock, reclaim: reclaim)
      admitWaiters()
    } else { idleWebSurfaces[id] = nil }
  }

  fileprivate func cancelIdleWebReclamation(_ id: UUID) {
    idleWebSurfaces[id] = nil
    guard retiringIdleWebSurfaces.remove(id) != nil else { return }
    admitWaiters()
  }

  /// Reading offers does not release anything. The planner addresses one
  /// concrete resource and checks the ledger again after its actual release.
  func registerReclamationOwner(_ offers: @escaping @MainActor () -> [SceneResourceReclamationCandidate]) -> UUID {
    let id = UUID(); reclamationOwners[id] = offers; return id
  }
  func unregisterReclamationOwner(_ id: UUID) { reclamationOwners[id] = nil }

  /// Visibility/contact changes can make an existing resource disposable even
  /// when no allocation was released. Wake admission from that owner event.
  func reclamationOffersChanged() {
    guard !derivedWaiters.isEmpty, reclamationNotification == nil else { return }
    reclamationNotification = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      reclamationNotification = nil
      admitDerivedWaiters()
    }
  }

  /// Optional work never occupies a pending position ahead of an actual source.
  /// Its live lease still consumes the ordinary background/passive allowances.
  func tryAcquireIdleWebSurface() -> WebSurfaceLease? {
    guard waiters.isEmpty, canAdmit(.background) else { return nil }
    return grantWebSurface(id: UUID(), priority: .background, source: nil)
  }

  private func reclaimUnusedWebIfNeeded(for priority: WebPriority) {
    guard !hasWebCapacity(priority), !isReclaimingIdleWeb, retiringIdleWebSurfaces.isEmpty else { return }
    let rasterBlocked = priority.preparesRaster && activeBackgroundWebSurfaceCount >= maximumBackgroundWebSurfaces
    let passiveBlocked = priority.isPassive && activePassiveWebSurfaceCount >= maximumWebSurfaces - reservedInteractiveSlots
    let candidates = idleWebSurfaces.filter { id, _ in
      guard let role = activeWebSurfaces[id] else { return false }
      return (!rasterBlocked || role.preparesRaster) && (!passiveBlocked || role.isPassive)
    }
    guard let selected = candidates.min(by: { $0.value.order < $1.value.order }) else { return }
    isReclaimingIdleWeb = true
    defer { isReclaimingIdleWeb = false }
    idleWebSurfaces[selected.key] = nil
    retiringIdleWebSurfaces.insert(selected.key)
    selected.value.reclaim()
    // Release may admit a waiter synchronously or await the final physical
    // borrow. Either way this request asks exactly one owner to retire.
  }
  private struct PhysicalOwnerEntry {
    var retains: Int
    var priority: SceneAllocationPriority
    var reservedBytes: Int = 0
  }
  private var physicalOwners: [ScenePhysicalOwner: PhysicalOwnerEntry] = [:]
  var activePhysicalOwnerCount: Int { physicalOwners.count }
  var retainedPhysicalOwners: Set<ScenePhysicalOwner> { Set(physicalOwners.keys) }

  /// Identity retention is not an allocation. The planner bounds each workset;
  /// old and incoming worksets must overlap until their native handoff finishes.
  /// Actual backing is still admitted by reserveDerivedBytes before allocation.
  func reservePhysicalOwners(_ owners: Set<ScenePhysicalOwner>, priority: SceneAllocationPriority = .passive) -> ScenePhysicalOwnerLease {
    for owner in owners {
      if physicalOwners[owner] != nil { physicalOwners[owner]?.retains += 1 }
      else { physicalOwners[owner] = .init(retains: 1, priority: priority) }
    }
    return .init(owners: owners, resources: self)
  }

  fileprivate func physicalPriority(for owner: ScenePhysicalOwner) -> SceneAllocationPriority? { physicalOwners[owner]?.priority }

  /// A portal handoff reclassifies both existing physical allocations at once.
  /// Per-owner byte totals avoid walking any samples or mesh batches on input.
  @discardableResult
  func updatePhysicalPriorities(_ updates: [ScenePhysicalOwner: SceneAllocationPriority]) -> Bool {
    var nextPassive = passiveReservedBytes
    var changed: [ScenePhysicalOwner: SceneAllocationPriority] = [:]
    for (id, priority) in updates {
      guard let entry = physicalOwners[id] else { return false }
      if entry.priority != priority {
        changed[id] = priority
        nextPassive += priority == .passive ? entry.reservedBytes : -entry.reservedBytes
      }
    }
    // updateUIView can reaffirm the same installed role. Mutating even an
    // equal @Observable value here invalidates that graph from its own update.
    guard !changed.isEmpty else { return true }
    guard makeRoom(for: 0, additionalEntry: false, priority: .passive, passiveReserved: nextPassive) else { return false }
    for (id, priority) in changed { physicalOwners[id]?.priority = priority }
    if passiveReservedBytes != nextPassive { passiveReservedBytes = nextPassive }
    return true
  }

  fileprivate func releasePhysicalOwners(_ owners: Set<ScenePhysicalOwner>) {
    for owner in owners {
      guard var entry = physicalOwners[owner], entry.retains > 0 else { continue }
      entry.retains -= 1
      if entry.retains == 0 && entry.reservedBytes == 0 { physicalOwners[owner] = nil }
      else { physicalOwners[owner] = entry }
    }
  }

  private struct RasterEntry {
    let source: SceneRasterSource
    let image: AgentSnapshotImage
    let mipmaps: [CGImage]
    let pixelScale: Double
    let cost: Int
    let documentLayout: DocumentLayoutRecord?
    let semanticSelection: ProgramSemanticSelection?
    // Publication order is immutable; borrowing an old receipt only changes
    // its eviction access, never which equal-density pixels are current.
    let publication: UInt64
    var access: UInt64
    var retains: Int
    // Only complete composition pixels are eligible for a warm return. This
    // metadata dies with the same budgeted entry; it retains no source images.
    var compositionReceipts: [SceneSourceAddress: SceneSourceReceipt]? = nil
  }
  private struct DiagnosticEntry {
    let element: AgentElement
    var values: [RenderDiagnostic]
    var access: UInt64
  }
  private enum WebExecutionSource: Hashable {
    case element(InteractiveElementReference)
    case document(UUID, String)
  }
  private struct WebWaiter {
    let id: UUID
    let priority: WebPriority
    let source: WebExecutionSource?
    let order: UInt64
    let continuation: CheckedContinuation<WebSurfaceLease, any Error>
  }
  private struct WebAvailability {
    let critical: Int
    let passive: Int
    let background: Int
    let queued: Int
    func improves(on previous: Self) -> Bool {
      critical > previous.critical || passive > previous.passive
        || background > previous.background || queued > previous.queued
    }
  }
  @ObservationIgnored private var entries: [UUID: RasterEntry] = [:]
  @ObservationIgnored private var rasterOwners: [RasterOwner: [UUID]] = [:]
  private struct ReservedAllocation {
    var bytes: Int
    let rasterCount: Int
    let priority: SceneAllocationPriority
    let physicalOwner: ScenePhysicalOwner?
  }
  @ObservationIgnored private var reservations: [UUID: ReservedAllocation] = [:]
  @ObservationIgnored private var reservedRasterCount = 0
  private struct DerivedWaiter {
    let id: UUID
    let bytes: Int
    let continuation: CheckedContinuation<RasterReservation, Error>
  }
  @ObservationIgnored private var derivedWaiters: [DerivedWaiter] = []
  var pendingDerivedRequestCount: Int { derivedWaiters.count }
  @ObservationIgnored private var diagnosticEntries: [String: DiagnosticEntry] = [:]
  @ObservationIgnored private var activeWebSurfaces: [UUID: WebPriority] = [:]
  @ObservationIgnored private var waiters: [WebWaiter] = []
  @ObservationIgnored private var accessClock: UInt64 = 0
  @ObservationIgnored private var waiterClock: UInt64 = 0

  init(byteLimit: Int = 256 * 1024 * 1024, profile: SceneResourceProfile = .interactive, maximumWebSurfaces: Int = 6,
    maximumBackgroundWebSurfaces: Int = 2, maximumPendingWebRequests: Int = 32,
    diagnosticCapacity: Int = 256, maximumRasterCount: Int = 2048, reservedInteractiveSlots: Int = 2) {
    precondition(byteLimit >= 0 && maximumWebSurfaces > 0 && maximumBackgroundWebSurfaces >= 0
      && maximumPendingWebRequests >= 0 && diagnosticCapacity >= 0 && maximumRasterCount >= 0
      && reservedInteractiveSlots >= 0)
    self.byteLimit = byteLimit; self.profile = profile
    #if os(iOS)
      passiveByteLimit = profile == .interactive ? byteLimit / 2 : byteLimit
    #else
      // AppKit ink uses the raster path, not the iPad input-backing allocator.
      // Keep its existing byte budget; windowed program ownership must not
      // silently halve the capacity available to every Mac raster and export.
      passiveByteLimit = byteLimit
    #endif
    self.maximumWebSurfaces = maximumWebSurfaces
    self.maximumBackgroundWebSurfaces = min(maximumWebSurfaces, maximumBackgroundWebSurfaces)
    self.maximumPendingWebRequests = maximumPendingWebRequests
    self.reservedInteractiveSlots = min(reservedInteractiveSlots, maximumWebSurfaces - 1)
    self.diagnosticCapacity = diagnosticCapacity; self.maximumRasterCount = maximumRasterCount
  }

  var rasterAdmission: SceneRasterAdmission {
    let pinned = entries.values.filter { $0.retains > 0 }
    return .init(pinnedBytes: pinned.reduce(0) { $0 + $1.cost }, reservedBytes: reservedBytes,
      pinnedCount: pinned.count, reservedCount: reservedRasterCount,
      byteLimit: byteLimit, countLimit: maximumRasterCount,
      passiveReservedBytes: passiveReservedBytes, passiveByteLimit: passiveByteLimit)
  }
  @ObservationIgnored private(set) var lastRasterRefusal: SceneRasterRefusal?
  @ObservationIgnored private var observedDocumentReservations: [UUID: [String: JSONValue]] = [:]
  @ObservationIgnored private var refusalGeneration: UInt64 = 0

  func image(for element: AgentElement, minimumScale: Double = 0) -> AgentSnapshotImage? {
    image(for: .agent(element), minimumScale: minimumScale)
  }
  func image(for source: SceneRasterSource, minimumScale: Double = 0) -> AgentSnapshotImage? {
    _ = rasterGeneration
    guard let id = matchingRaster(source, minimumScale: minimumScale) else { return nil }
    touchRaster(id)
    return entries[id]?.image
  }
  func retainRaster(for element: AgentElement, minimumScale: Double = 0) -> RasterLease? {
    retainRaster(for: .agent(element), minimumScale: minimumScale)
  }
  func retainRaster(for source: SceneRasterSource, minimumScale: Double = 0) -> RasterLease? {
    guard let id = matchingRaster(source, minimumScale: minimumScale) else { return nil }
    return retainRasterEntry(id)
  }
  fileprivate func retainRasterEntry(_ id: UUID) -> RasterLease? {
    guard var entry = entries[id] else { return nil }
    accessClock &+= 1; entry.access = accessClock; entry.retains += 1; entries[id] = entry
    return RasterLease(source: entry.source, pixelScale: entry.pixelScale, image: entry.image,
      mipmaps: entry.mipmaps, byteCount: entry.cost, entryID: id, semanticSelection: entry.semanticSelection, resources: self)
  }

  func compositionReceipts(for raster: RasterLease) -> [SceneSourceAddress: SceneSourceReceipt]? {
    guard !raster.isReleased else { return nil }
    return entries[raster.entryID]?.compositionReceipts
  }

  func retainComposition(_ key: SceneCompositionTileKey,
    accepts: ([SceneSourceAddress: SceneSourceReceipt]) -> Bool) -> RasterLease? {
    guard let id = matchingRaster(.composition(key), minimumScale: 0),
      let receipts = entries[id]?.compositionReceipts, accepts(receipts) else { return nil }
    return retainRasterEntry(id)
  }

  func cacheComposition(_ raster: RasterLease, receipts: [SceneSourceAddress: SceneSourceReceipt],
    sources: [SceneSourceAddress: RasterLease]) {
    guard !raster.isReleased, case .composition = raster.source,
      receipts.values.allSatisfy(\.hasCurrentPixels) else { return }
    for (address, receipt) in receipts {
      // Capture may finish during an awaited paint. Do not register the old
      // output as reusable after that newer source already invalidated caches.
      guard let source = sources[address], let entry = entries[source.entryID],
        source.image(for: receipt.demand.rasterSource, minimumScale: receipt.demand.minimumScale) != nil,
        !(rasterOwners[entry.source.owner] ?? []).contains(where: {
          (entries[$0]?.publication ?? 0) > entry.publication
        }) else { return }
    }
    entries[raster.entryID]?.compositionReceipts = receipts
  }

  func reserveWebSnapshot(pixelSize: CGSize) -> RasterReservation? {
    guard derivedWaiters.isEmpty, let budget = Self.webSnapshotBudget(pixelSize: pixelSize),
      makeRoom(for: budget.capture, additionalEntry: true, priority: .passive) else { return nil }
    return reserveAllocation(bytes: budget.capture, rasterCount: 1, priority: .passive, physicalOwner: nil)
  }

  /// One estimate for execution, retry and the scene's preflight. Both CPU
  /// pixels and GPU copies of every level remain charged through the same lease.
  nonisolated static func webSnapshotBudget(pixelSize: CGSize) -> (resident: Int, capture: Int)? {
    guard pixelSize.width.isFinite, pixelSize.height.isFinite,
      pixelSize.width >= 1, pixelSize.height >= 1,
      pixelSize.width < CGFloat(Int.max - 2), pixelSize.height < CGFloat(Int.max - 2) else { return nil }
    func cost(_ width: Int, _ height: Int) -> Int? {
      guard var total = estimatedRasterBytes(pixelWidth: width, pixelHeight: height,
        bytesPerPixel: webSnapshotBytesPerPixel) else { return nil }
      #if os(iOS)
      for size in mipmapSizes(width: width, height: height) {
        guard let level = estimatedRasterBytes(pixelWidth: size.width, pixelHeight: size.height) else { return nil }
        let sum = total.addingReportingOverflow(level)
        guard !sum.overflow else { return nil }
        total = sum.partialValue
      }
      #endif
      return total
    }
    let width = Int(pixelSize.width), height = Int(pixelSize.height)
    guard let resident = cost(width, height), let capture = cost(width + 2, height + 2) else { return nil }
    return (resident, capture)
  }

  nonisolated private static func mipmapSizes(width: Int, height: Int) -> [(width: Int, height: Int)] {
    var width = width, height = height, result: [(Int, Int)] = []
    while width > 1 || height > 1 {
      width = max(1, (width + 1) / 2); height = max(1, (height + 1) / 2)
      result.append((width, height))
    }
    return result
  }

  func reserveRaster(pixelWidth: Int, pixelHeight: Int, backingCount: Int = 2, bytesPerPixel: Int = 4) -> RasterReservation? {
    guard derivedWaiters.isEmpty, (1...16).contains(backingCount),
      let pair = Self.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: bytesPerPixel) else { return nil }
    let allocation = (pair / 2).multipliedReportingOverflow(by: backingCount)
    guard !allocation.overflow, makeRoom(for: allocation.partialValue, additionalEntry: true, priority: .passive) else { return nil }
    return reserveAllocation(bytes: allocation.partialValue, rasterCount: 1, priority: .passive, physicalOwner: nil)
  }

  /// Paper, clipped programs and composition output are admitted together.
  /// Every returned handle already owns both its bytes and its raster slot.
  func reserveRasterBatch(_ sizes: [(width: Int, height: Int)]) -> [RasterReservation]? {
    guard derivedWaiters.isEmpty, !sizes.isEmpty, sizes.count <= maximumRasterCount else { return nil }
    var costs: [Int] = [], total = 0
    for size in sizes {
      guard let cost = Self.estimatedRasterBytes(pixelWidth: size.width, pixelHeight: size.height),
        total <= Int.max - cost else { return nil }
      costs.append(cost); total += cost
    }
    guard makeRoom(for: total, additionalEntry: true, priority: .passive, entryCount: sizes.count) else { return nil }
    return costs.map { reserveAllocation(bytes: $0, rasterCount: 1, priority: .passive, physicalOwner: nil) }
  }

  /// A scene estimate consults the same owner as its later real allocations.
  /// Disposable readers get their ordinary reclamation opportunity before a
  /// candidate is rejected. This grants no bytes across subsequent awaits.
  func prepareRasterAdmission(additionalBytes: Int, additionalCount: Int) -> Bool {
    if additionalBytes == 0, additionalCount == 0 { return true }
    guard derivedWaiters.isEmpty else { return false }
    return makeRoom(for: additionalBytes, additionalEntry: additionalCount > 0,
      priority: .passive, entryCount: additionalCount)
  }

  func ownsRasterReservation(_ reservation: RasterReservation, pixelWidth: Int, pixelHeight: Int) -> Bool {
    guard reservation.resources === self, !reservation.isReleased,
      let allocation = reservations[reservation.id], allocation.rasterCount == 1,
      let bytes = Self.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { return false }
    return allocation.bytes >= bytes
  }

  /// Buffers and drawable backing compete with images for the same byte pool,
  /// but do not consume an image-cache entry or create another resource owner.
  func reserveDerivedBytes(_ byteCount: Int, priority: SceneAllocationPriority,
    owner: ScenePhysicalOwnerLease? = nil) -> RasterReservation? {
    guard priority != .passive || derivedWaiters.isEmpty else { return nil }
    var identity: ScenePhysicalOwner?
    if let owner {
      guard owner.resources === self, owner.owners.count == 1, let id = owner.owners.first,
        physicalOwners[id]?.priority == priority else { return nil }
      identity = id
    }
    guard byteCount > 0, makeRoom(for: byteCount, additionalEntry: false, priority: priority) else { return nil }
    return reserveAllocation(bytes: byteCount, rasterCount: 0, priority: priority, physicalOwner: identity)
  }

  /// A materialized bridge packet changes owner/size without an uncharged
  /// release-and-reacquire interval or a second full reservation. Growth is
  /// synchronous: the caller must discard materialized data before waiting.
  func resizePassiveDerivedReservation(_ reservation: RasterReservation, to byteCount: Int) -> Bool {
    guard reservation.resources === self, !reservation.isReleased, byteCount > 0,
      let allocation = reservations[reservation.id], allocation.rasterCount == 0,
      allocation.physicalOwner == nil, allocation.priority == .passive else { return false }
    let delta = byteCount - allocation.bytes
    guard delta <= 0 || derivedWaiters.isEmpty else { return false }
    guard delta <= 0 || makeRoom(for: delta, additionalEntry: false, priority: .passive) else { return false }
    let previous = rasterAdmission
    reservations[reservation.id]?.bytes = byteCount
    reservedBytes += delta; passiveReservedBytes += delta
    reservation.byteCount = byteCount
    peakAccountedBytes = max(peakAccountedBytes, residentBytes + reservedBytes)
    if delta < 0 { scheduleAdmissionNotification(previous) }
    return true
  }

  /// Divide already admitted capacity without re-entering admission. Neither
  /// a notification nor a competing waiter can observe these bytes as free.
  func splitPassiveDerivedReservation(_ reservation: RasterReservation, bytes: Int) -> RasterReservation? {
    guard isPassiveDerived(reservation), bytes > 0, bytes < reservation.byteCount else { return nil }
    reservations[reservation.id]?.bytes -= bytes
    reservation.byteCount -= bytes
    reservedBytes -= bytes; passiveReservedBytes -= bytes
    return reserveAllocation(bytes: bytes, rasterCount: 0, priority: .passive, physicalOwner: nil)
  }

  /// Move a stage's unused admission into a materialized value. The sum remains
  /// constant, including when the donor is exhausted and its handle retires.
  func transferPassiveDerivedReservation(_ donor: RasterReservation, to receiver: RasterReservation, bytes: Int) -> Bool {
    guard donor !== receiver, isPassiveDerived(donor), isPassiveDerived(receiver),
      bytes > 0, bytes <= donor.byteCount, receiver.byteCount <= Int.max - bytes else { return false }
    reservations[receiver.id]?.bytes += bytes; receiver.byteCount += bytes
    reservations[donor.id]?.bytes -= bytes; donor.byteCount -= bytes
    if donor.byteCount == 0 {
      reservations[donor.id] = nil; observedDocumentReservations[donor.id] = nil
      donor.release()
    }
    return true
  }

  private func isPassiveDerived(_ reservation: RasterReservation) -> Bool {
    guard reservation.resources === self, !reservation.isReleased,
      let allocation = reservations[reservation.id] else { return false }
    return allocation.rasterCount == 0 && allocation.physicalOwner == nil && allocation.priority == .passive
  }

  /// Required document work waits for the existing pool instead of poisoning
  /// its immutable source with a temporary refusal. No bytes are reserved while
  /// queued. The caller owns cancellation and its existing preparation deadline.
  func acquirePassiveDerivedBytes(_ byteCount: Int,
    onDeferred: @MainActor () -> Void = {}) async throws -> RasterReservation {
    try Task.checkCancellation()
    if derivedWaiters.isEmpty, let reservation = reserveDerivedBytes(byteCount, priority: .passive) { return reservation }
    onDeferred()
    guard byteCount > 0, byteCount <= passiveByteLimit,
      derivedWaiters.count < maximumPendingWebRequests else { throw SceneRenderError.resourceLimit }
    let id = UUID()
    let reservation: RasterReservation = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        derivedWaiters.append(.init(id: id, bytes: byteCount, continuation: continuation))
        admitDerivedWaiters()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelDerivedRequest(id) }
    }
    // A release and cancellation may reach this actor in either order.
    if Task.isCancelled { reservation.release(); throw CancellationError() }
    return reservation
  }

  private func cancelDerivedRequest(_ id: UUID) {
    guard let index = derivedWaiters.firstIndex(where: { $0.id == id }) else { return }
    derivedWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    admitDerivedWaiters()
  }

  private func admitDerivedWaiters() {
    // Preserve capacity for the oldest accepted stage. A stream of small
    // asynchronous requests cannot continually pass a large waiting stage.
    while let waiter = derivedWaiters.first {
      guard rasterAdmission.fits(additionalBytes: waiter.bytes, additionalCount: 0)
        || (pendingReclamations.isEmpty && reclamationOwners.values.contains(where: { !$0().isEmpty })) else { break }
      guard makeRoom(for: waiter.bytes, additionalEntry: false, priority: .passive),
        let index = derivedWaiters.firstIndex(where: { $0.id == waiter.id }) else { break }
      let reservation = reserveAllocation(bytes: waiter.bytes, rasterCount: 0, priority: .passive, physicalOwner: nil)
      derivedWaiters.remove(at: index).continuation.resume(returning: reservation)
    }
  }

  private func reserveAllocation(bytes: Int, rasterCount: Int, priority: SceneAllocationPriority,
    physicalOwner: ScenePhysicalOwner?) -> RasterReservation {
    let id = UUID()
    reservations[id] = .init(bytes: bytes, rasterCount: rasterCount, priority: priority, physicalOwner: physicalOwner)
    if priority == .passive { passiveReservedBytes += bytes }
    if let physicalOwner { physicalOwners[physicalOwner]?.reservedBytes += bytes }
    reservedBytes += bytes; reservedRasterCount += rasterCount
    peakAccountedBytes = max(peakAccountedBytes, residentBytes + reservedBytes)
    return RasterReservation(id: id, byteCount: bytes, resources: self)
  }

  /// Private acceptance provenance attaches to the existing allocation. It
  /// neither adds a retain nor changes admission, eviction or release order.
  func observeDocumentReservation(_ reservation: RasterReservation, documentID: UUID,
    sourceKey: String, page: Int?, purpose: String) {
    guard NotebookNavigationObservation.enabled, reservation.resources === self,
      reservations[reservation.id] != nil else { return }
    observedDocumentReservations[reservation.id] = ["documentID": .string(documentID.uuidString),
      "sourceKey": .string(String(sourceKey.prefix(80))), "purpose": .string(String(purpose.prefix(80))),
      "page": page.map { .number(Double($0)) } ?? .null]
  }

  /// Bounded, read-only inventory; totals are exact, individual holders are
  /// explicitly truncated after 64 entries. Source text and pixels are omitted.
  func documentAllocationObservation() -> [String: JSONValue] {
    guard NotebookNavigationObservation.enabled else { return [:] }
    let admission = rasterAdmission
    let reservationSample = reservations.prefix(64)
    let rasterSample = entries.prefix(64)
    return ["byteLimit": .number(Double(admission.byteLimit)),
      "passiveByteLimit": .number(Double(admission.passiveByteLimit)),
      "residentBytes": .number(Double(residentBytes)), "reservedBytes": .number(Double(reservedBytes)),
      "pinnedBytes": .number(Double(admission.pinnedBytes)),
      "passiveReservedBytes": .number(Double(admission.passiveReservedBytes)),
      "reservationCount": .number(Double(reservations.count)), "rasterCount": .number(Double(entries.count)),
      "activeWebSurfaces": .number(Double(activeWebSurfaceCount)),
      "pendingWebRequests": .number(Double(pendingWebRequestCount)),
      "holdersTruncated": .bool(reservations.count > 64 || entries.count > 64),
      "reservations": .array(reservationSample.map { id, allocation in
        var value = observedDocumentReservations[id] ?? [:]
        value["id"] = .string(id.uuidString); value["bytes"] = .number(Double(allocation.bytes))
        let priority = allocation.physicalOwner.flatMap { physicalOwners[$0]?.priority } ?? allocation.priority
        value["priority"] = .string(priority == .passive ? "passive" : "input")
        value["physicalOwner"] = .bool(allocation.physicalOwner != nil)
        return .object(value)
      }),
      "rasters": .array(rasterSample.map { id, entry in
        let kind: String, documentID: UUID?, renderToken: String?
        switch entry.source {
        case .document(let id, let token): kind = "document"; documentID = id; renderToken = token
        case .agent: kind = "agent"; documentID = nil; renderToken = nil
        case .agentRegion: kind = "agent_region"; documentID = nil; renderToken = nil
        case .composition: kind = "composition"; documentID = nil; renderToken = nil
        }
        return .object(["id": .string(id.uuidString), "kind": .string(kind),
          "documentID": documentID.map { .string($0.uuidString) } ?? .null,
          "renderToken": renderToken.map { .string(String($0.prefix(160))) } ?? .null,
          "bytes": .number(Double(entry.cost)), "retains": .number(Double(entry.retains)),
          "ownsLayout": .bool(entry.documentLayout != nil)])
      })]
  }

  @discardableResult
  func store(_ image: AgentSnapshotImage, for element: AgentElement,
    reservation: RasterReservation? = nil) -> Bool {
    store(image, for: .agent(element), reservation: reservation)
  }
  @discardableResult
  func store(_ image: AgentSnapshotImage, for source: SceneRasterSource,
    reservation: RasterReservation? = nil, documentLayout: DocumentLayoutRecord? = nil) -> Bool {
    installRaster(image, for: source, reservation: reservation, documentLayout: documentLayout) != nil
  }

  /// A source owns its minification pixels, not each view or camera position.
  /// NPOT images need explicit levels on renderers that ignore trilinear mipmaps.
  /// This keeps the original exact pixels and adds about a third, not POT padding.
  func storeWebSnapshot(_ image: AgentSnapshotImage, for source: SceneRasterSource,
    reservation: RasterReservation, semanticSelection: ProgramSemanticSelection? = nil, permitsPublication: @MainActor () -> Bool = { true }) async -> RasterLease? {
    guard !Task.isCancelled, permitsPublication() else { return nil }
    #if os(iOS)
    guard !reservation.isReleased, reservation.resources === self,
      let allocation = reservations[reservation.id], let original = image.cgImage,
      let base = Self.rasterDescription(image, source: source, mipmaps: []) else { return nil }
    let sizes = Self.mipmapSizes(width: original.width, height: original.height)
    var required = base.cost
    for size in sizes {
      guard let cost = Self.estimatedRasterBytes(pixelWidth: size.width, pixelHeight: size.height) else { return nil }
      let sum = required.addingReportingOverflow(cost)
      guard !sum.overflow, sum.partialValue <= allocation.bytes else { return nil }
      required = sum.partialValue
    }
    guard let levels = try? await CompositionPixels.makeMipmaps(original, sizes: sizes),
      !Task.isCancelled, permitsPublication() else { return nil }
    return storeAndRetain(image, for: source, reservation: reservation, mipmaps: levels, semanticSelection: semanticSelection)
    #else
    return storeAndRetain(image, for: source, reservation: reservation, semanticSelection: semanticSelection)
    #endif
  }

  /// An observed live frame must retain the entry just captured. A cache lookup
  /// could select an older higher-density image of the same program/state.
  func storeAndRetain(_ image: AgentSnapshotImage, for source: SceneRasterSource,
    reservation: RasterReservation, documentLayout: DocumentLayoutRecord? = nil, mipmaps: [CGImage] = [], semanticSelection: ProgramSemanticSelection? = nil) -> RasterLease? {
    guard let id = installRaster(image, for: source, reservation: reservation, documentLayout: documentLayout, retaining: true, mipmaps: mipmaps, semanticSelection: semanticSelection),
      let entry = entries[id] else { return nil }
    return RasterLease(source: entry.source, pixelScale: entry.pixelScale, image: entry.image,
      mipmaps: entry.mipmaps, byteCount: entry.cost, entryID: id, semanticSelection: entry.semanticSelection, resources: self)
  }

  private func installRaster(_ image: AgentSnapshotImage, for source: SceneRasterSource,
    reservation: RasterReservation?, documentLayout: DocumentLayoutRecord?, retaining: Bool = false, mipmaps: [CGImage] = [], semanticSelection: ProgramSemanticSelection? = nil) -> UUID? {
    guard let raster = Self.rasterDescription(image, source: source, mipmaps: mipmaps) else { return nil }
    let previous = rasterAdmission
    if let reservation {
      guard !reservation.isReleased, reservation.resources === self,
        let allocation = reservations[reservation.id], raster.cost <= allocation.bytes,
        allocation.rasterCount > 0 || makeRoom(for: 0, additionalEntry: true, priority: .passive) else { return nil }
    } else if !derivedWaiters.isEmpty || !makeRoom(for: raster.cost, additionalEntry: true, priority: .passive) {
      if let element = source.agentElement {
        record(.init(kind: "resource_limit", elementID: element.id,
          message: "Недостаточно ресурсов для точного снимка"), for: element)
      }
      return nil
    }
    // A retained older raster is a distinct accounted entry until its lease ends.
    for id in rasterOwners[source.owner] ?? [] {
      if let entry = entries[id], entry.source == source, entry.retains == 0,
        entry.pixelScale <= raster.scale { removeRaster(id) }
    }
    // Retire old cache entries while this grant is still charged: their change
    // observers cannot consume capacity promised to these incoming pixels.
    if let reservation {
      releaseReservation(reservation.id, notifies: false)
      reservation.release()
    }
    accessClock &+= 1
    let id = UUID()
    entries[id] = RasterEntry(source: source, image: image, mipmaps: mipmaps, pixelScale: raster.scale,
      cost: raster.cost, documentLayout: documentLayout, semanticSelection: semanticSelection, publication: accessClock, access: accessClock, retains: retaining ? 1 : 0)
    rasterOwners[source.owner, default: []].append(id)
    residentBytes += raster.cost; rasterCount = entries.count
    scheduleAdmissionNotification(previous)
    peakAccountedBytes = max(peakAccountedBytes, residentBytes + reservedBytes)
    if let element = source.agentElement, var diagnostics = diagnosticEntries[element.id], diagnostics.element == element {
      diagnostics.values.removeAll { $0.kind == "resource_limit" }
      diagnosticEntries[element.id] = diagnostics
    }
    if let element = source.agentElement {
      // A new capture may have the same durable source/state as its previous
      // frame. Revoke dependent cache eligibility, never displayed leases.
      for id in entries.keys where entries[id]?.compositionReceipts?.keys.contains(where: { $0.elementID == element.id }) == true {
        entries[id]?.compositionReceipts = nil
      }
    }
    changed(source.owner)
    return id
  }

  func record(_ diagnostic: RenderDiagnostic, for element: AgentElement) {
    guard diagnosticCapacity > 0 else { return }
    accessClock &+= 1
    var entry = diagnosticEntries[element.id].flatMap { $0.element == element ? $0 : nil }
      ?? DiagnosticEntry(element: element, values: [], access: accessClock)
    if !entry.values.contains(diagnostic) { entry.values.append(diagnostic) }
    entry.values = Array(entry.values.suffix(32)); entry.access = accessClock
    diagnosticEntries[element.id] = entry
    while diagnosticEntries.count > diagnosticCapacity,
      let oldest = diagnosticEntries.min(by: { $0.value.access < $1.value.access })?.key {
      diagnosticEntries[oldest] = nil
    }
  }
  func diagnostics(for elements: [AgentElement]) -> [RenderDiagnostic] {
    elements.flatMap { element in
      diagnosticEntries[element.id].flatMap { $0.element == element ? $0.values : nil } ?? []
    }
  }
  var diagnosticOwnerCount: Int { diagnosticEntries.count }

  func acquireWebSurface(priority: WebPriority, source: InteractiveElementReference? = nil,
    deadline: ContinuousClock.Instant? = nil) async throws -> WebSurfaceLease {
    try await acquireWebSurface(priority: priority, executionSource: source.map(WebExecutionSource.element), deadline: deadline)
  }

  func acquireDocumentProgramSurface(priority: WebPriority, documentID: UUID, blockID: String,
    deadline: ContinuousClock.Instant? = nil) async throws -> WebSurfaceLease {
    try await acquireWebSurface(priority: priority, executionSource: .document(documentID, blockID), deadline: deadline)
  }

  private func acquireWebSurface(priority: WebPriority, executionSource source: WebExecutionSource?,
    deadline: ContinuousClock.Instant?) async throws -> WebSurfaceLease {
    try Task.checkCancellation()
    guard !priority.preparesRaster || maximumBackgroundWebSurfaces > 0 else { throw SceneRenderError.resourceLimit }
    let id = UUID()
    let timeout = deadline.map { deadline in
      Task { @MainActor [weak self] in
        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
        self?.cancelWebRequest(id, error: SceneRenderError.resourceLimit)
      }
    }
    defer { timeout?.cancel() }
    let lease: WebSurfaceLease = try await withTaskCancellationHandler(operation: { () async throws -> WebSurfaceLease in
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSurfaceLease, any Error>) in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        // Every eligible older waiter has already been admitted. Remaining
        // waiters are quota-blocked, so a reserved critical slot must not need
        // a spare position in their full passive queue.
        reclaimUnusedWebIfNeeded(for: priority)
        if canAdmit(priority, source: source) {
          continuation.resume(returning: grantWebSurface(id: id, priority: priority, source: source))
          return
        }
        guard waiters.count < maximumPendingWebRequests else {
          continuation.resume(throwing: SceneRenderError.resourceLimit); return
        }
        waiterClock &+= 1
        waiters.append(WebWaiter(id: id, priority: priority, source: source, order: waiterClock, continuation: continuation))
        waiters.sort { $0.priority == $1.priority ? $0.order < $1.order : $0.priority < $1.priority }
        pendingWebRequestCount = waiters.count
        admitWaiters()
      }
    }, onCancel: {
      Task { @MainActor [weak self] in self?.cancelWebRequest(id) }
    })
    // Cancellation can race with a release that admitted this waiter before the
    // cancellation handler reached the main actor. Never hand that slot to a
    // cancelled caller, and release it without waiting for ARC.
    if Task.isCancelled { lease.release(); throw CancellationError() }
    return lease
  }

  fileprivate func releaseRaster(_ id: UUID) {
    guard var entry = entries[id], entry.retains > 0 else { return }
    let previous = rasterAdmission
    entry.retains -= 1; entries[id] = entry
    if entry.retains == 0 { scheduleAdmissionNotification(previous) }
  }
  fileprivate func releaseReservation(_ id: UUID, notifies: Bool = true) {
    observedDocumentReservations[id] = nil
    let previous = rasterAdmission
    if let allocation = reservations.removeValue(forKey: id) {
      let priority = allocation.physicalOwner.flatMap { physicalOwners[$0]?.priority } ?? allocation.priority
      if priority == .passive { passiveReservedBytes -= allocation.bytes }
      if let id = allocation.physicalOwner, var owner = physicalOwners[id] {
        owner.reservedBytes -= allocation.bytes
        if owner.retains == 0 && owner.reservedBytes == 0 { physicalOwners[id] = nil }
        else { physicalOwners[id] = owner }
      }
      reservedBytes -= allocation.bytes; reservedRasterCount -= allocation.rasterCount
      if notifies { scheduleAdmissionNotification(previous) }
    }
  }

  private func scheduleAdmissionNotification(_ previous: SceneRasterAdmission) {
    guard admissionNotification == nil else { return }
    admissionNotification = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      admissionNotification = nil
      let current = rasterAdmission
      guard current.byteLimit - current.heldBytes > previous.byteLimit - previous.heldBytes
        || current.passiveByteLimit - current.pinnedBytes - current.passiveReservedBytes
          > previous.passiveByteLimit - previous.pinnedBytes - previous.passiveReservedBytes
        || current.countLimit - current.pinnedCount - current.reservedCount
          > previous.countLimit - previous.pinnedCount - previous.reservedCount else { return }
      rasterAdmissionGeneration &+= 1
      admitDerivedWaiters()
      NotificationCenter.default.post(name: Self.didGainRasterAdmission, object: self)
    }
  }
  fileprivate func releaseWebSurface(_ id: UUID) {
    let availability = webAvailability
    guard let priority = activeWebSurfaces.removeValue(forKey: id) else { return }
    activeWebSources[id] = nil; idleWebSurfaces[id] = nil; retiringIdleWebSurfaces.remove(id)
    activeWebSurfaceCount = activeWebSurfaces.count
    if priority.preparesRaster { activeBackgroundWebSurfaceCount -= 1 }
    if priority.isPassive { activePassiveWebSurfaceCount -= 1 }
    admitWaiters()
    publishWebAvailability(after: availability)
  }
  fileprivate func updateWebPriority(_ id: UUID, priority: WebPriority) {
    let availability = webAvailability
    guard let previous = activeWebSurfaces[id], previous != priority else { return }
    activeWebSurfaces[id] = priority
    if previous.preparesRaster { activeBackgroundWebSurfaceCount -= 1 }
    if priority.preparesRaster { activeBackgroundWebSurfaceCount += 1 }
    if previous.isPassive { activePassiveWebSurfaceCount -= 1 }
    if priority.isPassive { activePassiveWebSurfaceCount += 1 }
    // Existing contacts may temporarily exceed a passive role quota after a
    // handoff. Preserve their leases and admit no new work until below quota.
    admitWaiters()
    publishWebAvailability(after: availability)
  }

  @ObservationIgnored private var activeWebSources: [UUID: WebExecutionSource] = [:]
  @ObservationIgnored private var webAdmissionSerial: UInt64 = 0
  @ObservationIgnored private var recentWebSourceAdmissions: [WebExecutionSource: UInt64] = [:]
  struct WebSourceActivity: Equatable {
    let activeLeaseCount: Int
    /// Identifies the last actual grant, not an unrelated availability change.
    let lastAdmission: UInt64?
  }
  func webActivity(for reference: InteractiveElementReference) -> WebSourceActivity {
    let source = WebExecutionSource.element(reference)
    return .init(activeLeaseCount: activeWebSources.values.filter { $0 == source }.count,
      lastAdmission: recentWebSourceAdmissions[source])
  }
  private func hasWebCapacity(_ priority: WebPriority) -> Bool {
    activeWebSurfaces.count < maximumWebSurfaces
      && (!priority.preparesRaster || activeBackgroundWebSurfaceCount < maximumBackgroundWebSurfaces)
      && (!priority.isPassive || activePassiveWebSurfaceCount < maximumWebSurfaces - reservedInteractiveSlots)
      && (priority != .liveProgram || activeWebSurfaces.count - activeBackgroundWebSurfaceCount
        < maximumWebSurfaces - (maximumWebSurfaces > 1 && maximumBackgroundWebSurfaces > 0 ? 1 : 0))
  }
  private func canAdmit(_ priority: WebPriority, source: WebExecutionSource? = nil) -> Bool {
    hasWebCapacity(priority) && (source.map { !activeWebSources.values.contains($0) } ?? true)
  }
  private func grantWebSurface(id: UUID, priority: WebPriority, source: WebExecutionSource? = nil) -> WebSurfaceLease {
    activeWebSurfaces[id] = priority
    activeWebSources[id] = source
    if let source {
      webAdmissionSerial &+= 1
      recentWebSourceAdmissions[source] = webAdmissionSerial
      if recentWebSourceAdmissions.count > max(maximumWebSurfaces, diagnosticCapacity),
        let oldest = recentWebSourceAdmissions.filter({ !activeWebSources.values.contains($0.key) })
          .min(by: { $0.value < $1.value })?.key {
        recentWebSourceAdmissions[oldest] = nil
      }
    }
    activeWebSurfaceCount = activeWebSurfaces.count
    if priority.preparesRaster { activeBackgroundWebSurfaceCount += 1 }
    if priority.isPassive { activePassiveWebSurfaceCount += 1 }
    return WebSurfaceLease(id: id, priority: priority, resources: self)
  }
  private func admitWaiters() {
    if let priority = waiters.first?.priority { reclaimUnusedWebIfNeeded(for: priority) }
    while let position = waiters.firstIndex(where: { canAdmit($0.priority, source: $0.source) }) {
      let waiter = waiters.remove(at: position)
      pendingWebRequestCount = waiters.count
      waiter.continuation.resume(returning: grantWebSurface(id: waiter.id, priority: waiter.priority, source: waiter.source))
    }
  }
  private func cancelWebRequest(_ id: UUID, error: any Error = CancellationError()) {
    let availability = webAvailability
    guard let position = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: position)
    pendingWebRequestCount = waiters.count
    waiter.continuation.resume(throwing: error)
    admitWaiters()
    publishWebAvailability(after: availability)
  }

  private var webAvailability: WebAvailability {
    let critical = max(0, maximumWebSurfaces - activeWebSurfaces.count)
    let passive = min(critical, max(0, maximumWebSurfaces - reservedInteractiveSlots - activePassiveWebSurfaceCount))
    return .init(critical: critical, passive: passive,
      background: min(passive, max(0, maximumBackgroundWebSurfaces - activeBackgroundWebSurfaceCount)),
      queued: max(0, maximumPendingWebRequests - waiters.count))
  }
  private func publishWebAvailability(after previous: WebAvailability) {
    if webAvailability.improves(on: previous) { webAdmissionGeneration &+= 1 }
  }

  private func matchingRaster(_ source: SceneRasterSource, minimumScale: Double) -> UUID? {
    precondition(minimumScale.isFinite && minimumScale >= 0)
    return rasterOwners[source.owner]?.filter { id in
      guard let entry = entries[id] else { return false }
      return entry.source == source && entry.pixelScale + 0.000_001 >= minimumScale
    }.max { left, right in
      let a = entries[left]!, b = entries[right]!
      return a.pixelScale == b.pixelScale ? a.publication < b.publication : a.pixelScale < b.pixelScale
    }
  }
  private func touchRaster(_ id: UUID) {
    guard var entry = entries[id] else { return }
    accessClock &+= 1; entry.access = accessClock; entries[id] = entry
  }
  private func makeRoom(for cost: Int, additionalEntry: Bool, priority: SceneAllocationPriority,
    passiveReserved: Int? = nil, entryCount: Int? = nil, attempted: Set<UUID> = []) -> Bool {
    let passiveAdjustment = (passiveReserved ?? passiveReservedBytes) - passiveReservedBytes
    let passiveCost = priority == .passive ? cost : 0
    guard cost >= 0, cost <= byteLimit, passiveCost <= passiveByteLimit,
      passiveReservedBytes + passiveAdjustment >= 0,
      !additionalEntry || maximumRasterCount > 0 else { return refuseRaster(cost: cost, additionalEntry: additionalEntry) }
    let neededCount = entryCount ?? (additionalEntry ? 1 : 0)
    guard neededCount >= 0, neededCount <= maximumRasterCount else { return false }
    // Keep only IDs here. Copying entries would retain the very layout leases
    // that eviction must release before the next admission calculation.
    let candidates = entries.keys.filter { entries[$0]!.retains == 0 }.sorted { entries[$0]!.access < entries[$1]!.access }
    func residentLimit() -> Int {
      min(byteLimit - reservedBytes - cost,
        passiveByteLimit - passiveReservedBytes - passiveAdjustment - passiveCost)
    }
    var position = 0
    while residentBytes > residentLimit()
      || entries.count + reservedRasterCount + neededCount > maximumRasterCount {
      if position < candidates.count {
        removeRaster(candidates[position]); position += 1
        continue
      }
      if !isReclaimingIdleResources, passiveReserved == nil, pendingReclamations.isEmpty,
        let candidate = SceneResourceReclamationPlanner.next(
          reclamationOwners.values.flatMap { $0() }.filter { !attempted.contains($0.id) },
          bytes: max(0, residentBytes - residentLimit()),
          count: max(0, entries.count + reservedRasterCount + neededCount - maximumRasterCount)) {
        isReclaimingIdleResources = true
        let before = rasterAdmission
        let completion = candidate.release()
        isReclaimingIdleResources = false
        if let completion {
          pendingReclamations.insert(candidate.id)
          Task { @MainActor [weak self] in
            await completion.value
            guard let self else { return }
            pendingReclamations.remove(candidate.id)
            scheduleAdmissionNotification(before)
          }
        }
        return makeRoom(for: cost, additionalEntry: additionalEntry, priority: priority,
          entryCount: entryCount, attempted: attempted.union([candidate.id]))
      }
      return refuseRaster(cost: cost, additionalEntry: additionalEntry)
    }
    return true
  }
  private func refuseRaster(cost: Int, additionalEntry: Bool) -> Bool {
    refusalGeneration &+= 1
    lastRasterRefusal = .init(generation: refusalGeneration, requestedBytes: cost,
      requestedCount: additionalEntry ? 1 : 0, admission: rasterAdmission)
    return false
  }
  private func removeRaster(_ id: UUID) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    precondition(entry.retains == 0)
    residentBytes -= entry.cost; rasterCount = entries.count
    rasterOwners[entry.source.owner]?.removeAll { $0 == id }
    if rasterOwners[entry.source.owner]?.isEmpty == true { rasterOwners[entry.source.owner] = nil }
    changed(entry.source.owner)
  }
  private func changed(_ owner: RasterOwner) {
    rasterGeneration &+= 1
    let id: Any
    switch owner {
    case .agent(let element): id = element
    case .document(let document): id = document
    case .composition(let tile): id = tile
    }
    NotificationCenter.default.post(name: Self.didChange, object: id)
  }

  // AppKit WebKit snapshots use 64-bit extended-color pixels. Keep that
  // precision and charge it before capture, not by exceeding a 32-bit grant.
  #if os(macOS)
  nonisolated static let webSnapshotBytesPerPixel = 8
  #else
  nonisolated static let webSnapshotBytesPerPixel = 4
  #endif

  nonisolated static func estimatedRasterBytes(pixelWidth: Int, pixelHeight: Int, bytesPerPixel: Int = 4) -> Int? {
    guard pixelWidth > 0, pixelHeight > 0, [4, 8].contains(bytesPerPixel) else { return nil }
    let (rawRow, overflow) = pixelWidth.multipliedReportingOverflow(by: bytesPerPixel)
    guard !overflow, rawRow <= Int.max - 63 else { return nil }
    let row = ((rawRow + 63) / 64) * 64
    let (pixels, rowsOverflow) = row.multipliedReportingOverflow(by: pixelHeight)
    let (cost, copiesOverflow) = pixels.multipliedReportingOverflow(by: 2)
    return rowsOverflow || copiesOverflow ? nil : cost
  }
  private static func rasterDescription(_ image: AgentSnapshotImage,
    source: SceneRasterSource, mipmaps: [CGImage]) -> (cost: Int, scale: Double)? {
    #if os(iOS)
      guard let cgImage = image.cgImage else { return nil }
    #else
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #endif
    let (bytes, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
    let (cost, doubledOverflow) = bytes.multipliedReportingOverflow(by: 2)
    guard !overflow, !doubledOverflow, cost > 0 else { return nil }
    var total = cost
    for level in mipmaps {
      let bytes = level.bytesPerRow.multipliedReportingOverflow(by: level.height)
      let copies = bytes.partialValue.multipliedReportingOverflow(by: 2)
      let sum = total.addingReportingOverflow(copies.partialValue)
      guard !bytes.overflow, !copies.overflow, !sum.overflow else { return nil }
      total = sum.partialValue
    }
    let size: CGSize
    switch source {
    case .agent(let element): size = .init(width: element.frame.width, height: element.frame.height)
    case .agentRegion(_, let region): size = .init(width: region.width, height: region.height)
    case .document, .composition: size = image.size
    }
    guard size.width > 0, size.height > 0 else { return nil }
    let horizontal = Double(cgImage.width) / size.width
    let vertical = Double(cgImage.height) / size.height
    guard abs(horizontal - vertical) <= max(1 / size.width, 1 / size.height) + 0.000_001 else { return nil }
    return (total, min(horizontal, vertical))
  }

  /// Every caller uses the same granted executor and receives the exact entry
  /// it prepared. A large composition can release each source after painting it.
  func prepareRaster(_ element: AgentElement, requestedScale: Double = 2, region: PageRect? = nil,
    executionSource: InteractiveElementReference? = nil,
    captureRequest: SceneRasterCaptureRequest? = nil, programStore: NotebookStore? = nil,
    permitsPreparation: @MainActor () -> Bool = { true }) async throws -> RasterLease {
    try Task.checkCancellation()
    let policy = captureRequest?.policy ?? region.map { AgentSnapshotPolicy.region($0, scale: requestedScale) }
      ?? .exact(scale: requestedScale)
    if let raster = retainRaster(for: policy.rasterSource(for: element), minimumScale: policy.minimumScale(for: element)) { return raster }
    let preparation = try await SceneWebRasterPreparation.create(resources: self, executionSource: executionSource,
      permitsPreparation: permitsPreparation)
    defer { preparation.close() }
    return try await preparation.prepare(element, requestedScale: requestedScale, region: region,
      captureRequest: captureRequest, programStore: programStore, permitsPreparation: permitsPreparation)
  }

}

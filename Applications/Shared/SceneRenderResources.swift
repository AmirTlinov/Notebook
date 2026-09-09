import Foundation
import NotebookCore
import Observation
import SwiftUI
import WebKit

enum SceneRasterSource: Equatable, Sendable {
  case agent(AgentElement)
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
        && left.css == right.css && left.javaScript == right.javaScript && left.state == right.state
    case (.document(let leftID, let leftToken), .document(let rightID, let rightToken)):
      leftID == rightID && leftToken == rightToken
    case (.composition(let left), .composition(let right)): left == right
    default: false
    }
  }

  fileprivate var owner: RasterOwner {
    switch self {
    case .agent(let element): .agent(element.id)
    case .document(let id, _): .document(id)
    case .composition(let key): .composition(key)
    }
  }
}

fileprivate enum RasterOwner: Hashable { case agent(String), document(UUID), composition(SceneCompositionTileKey) }

enum WebPriority: Int, Comparable, Sendable {
  case currentPage, input, neighbor, visible, background
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  /// Visible source preparation and export preparation share the same executor
  /// allowance. Neighbor pages are already live physical sheets, not raster jobs.
  fileprivate var preparesRaster: Bool { self == .visible || self == .background }
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

/// Headless export has no future Pencil contact. An interactive scene reserves
/// half of this same pool; it does not acquire a second allocator or quota.
enum SceneResourceProfile: Equatable, Sendable {
  case interactive, headless
  static var currentPlatform: Self {
    #if os(iOS)
      .interactive
    #else
      .headless
    #endif
  }
}

/// A retained image is charged until its final lease ends. Released leases cannot
/// keep an unaccounted strong image reference alive.
@MainActor
final class RasterLease {
  let source: SceneRasterSource
  let pixelScale: Double
  let accountedByteCount: Int
  let entryID: UUID
  private var resources: SceneRenderResources?
  private var retainedImage: AgentSnapshotImage?
  var isReleased: Bool { resources == nil }
  var image: AgentSnapshotImage {
    precondition(!isReleased, "A released raster lease has no image")
    return retainedImage!
  }
  /// Snapshot composition reads this retained entry, never a newer cache alias.
  func image(for source: SceneRasterSource, minimumScale: Double = 0) -> AgentSnapshotImage? {
    precondition(minimumScale.isFinite && minimumScale >= 0)
    guard !isReleased, self.source == source, pixelScale + 0.000_001 >= minimumScale else { return nil }
    return retainedImage
  }
  fileprivate init(source: SceneRasterSource, pixelScale: Double, image: AgentSnapshotImage,
    byteCount: Int, entryID: UUID, resources: SceneRenderResources) {
    self.source = source; self.pixelScale = pixelScale; retainedImage = image; accountedByteCount = byteCount
    self.entryID = entryID; self.resources = resources
  }
  func retainedCopy() -> RasterLease? {
    resources?.retainRasterEntry(entryID)
  }
  func release() {
    guard let owner = resources else { return }
    resources = nil; retainedImage = nil
    owner.releaseRaster(entryID)
  }
  isolated deinit { release() }
}

/// Reserves derived CPU/GPU backing before its allocation. GPU users retain
/// this lease until the last submitted command has completed, not just unmount.
@MainActor
final class RasterReservation {
  let byteCount: Int
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
  var isReleased: Bool { resources == nil }
  fileprivate init(id: UUID, priority: WebPriority, resources: SceneRenderResources) {
    self.id = id; self.priority = priority; self.resources = resources
  }
  func release() {
    guard let owner = resources else { return }
    resources = nil
    owner.releaseWebSurface(id)
  }
  /// A page curl transfers the already mounted owner between current and
  /// neighbor roles. Reclassification never replaces or revokes its WebKit.
  func updatePriority(_ priority: WebPriority) {
    guard let resources, self.priority != priority else { return }
    self.priority = priority
    resources.updateWebPriority(id, priority: priority)
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

/// One admission owner for derived rasters and WebKit execution. Content and
/// interactive state remain in their existing documents; this store is disposable.
@MainActor
@Observable
final class SceneRenderResources {
  static let shared = SceneRenderResources()
  static let didChange = Notification.Name("NotebookSceneRenderResourcesDidChange")
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
  private struct PhysicalOwnerEntry {
    var retains: Int
    var priority: SceneAllocationPriority
    var reservedBytes: Int = 0
  }
  private var physicalOwners: [ScenePhysicalOwner: PhysicalOwnerEntry] = [:]
  var activePhysicalOwnerCount: Int { physicalOwners.count }
  var retainedPhysicalOwners: Set<ScenePhysicalOwner> { Set(physicalOwners.keys) }

  /// Candidate and shown cohorts share IDs, not two independent eight-owner
  /// quotas. Admission precedes construction of a new native physical canvas.
  func reservePhysicalOwners(_ owners: Set<ScenePhysicalOwner>, priority: SceneAllocationPriority = .passive) -> ScenePhysicalOwnerLease? {
    guard Set(physicalOwners.keys).union(owners).count <= SceneCompositionPlan.maximumLiveOwners else { return nil }
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
    let pixelScale: Double
    let cost: Int
    var access: UInt64
    var retains: Int
  }
  private struct DiagnosticEntry {
    let element: AgentElement
    var values: [RenderDiagnostic]
    var access: UInt64
  }
  private struct WebWaiter {
    let id: UUID
    let priority: WebPriority
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
    let bytes: Int
    let rasterCount: Int
    let priority: SceneAllocationPriority
    let physicalOwner: ScenePhysicalOwner?
  }
  @ObservationIgnored private var reservations: [UUID: ReservedAllocation] = [:]
  @ObservationIgnored private var reservedRasterCount = 0
  @ObservationIgnored private var diagnosticEntries: [String: DiagnosticEntry] = [:]
  @ObservationIgnored private var activeWebSurfaces: [UUID: WebPriority] = [:]
  @ObservationIgnored private var waiters: [WebWaiter] = []
  @ObservationIgnored private var accessClock: UInt64 = 0
  @ObservationIgnored private var waiterClock: UInt64 = 0

  init(byteLimit: Int = 256 * 1024 * 1024, profile: SceneResourceProfile = .currentPlatform, maximumWebSurfaces: Int = 6,
    maximumBackgroundWebSurfaces: Int = 2, maximumPendingWebRequests: Int = 32,
    diagnosticCapacity: Int = 256, maximumRasterCount: Int = 2048, reservedInteractiveSlots: Int = 2) {
    precondition(byteLimit >= 0 && maximumWebSurfaces > 0 && maximumBackgroundWebSurfaces >= 0
      && maximumPendingWebRequests >= 0 && diagnosticCapacity >= 0 && maximumRasterCount >= 0
      && reservedInteractiveSlots >= 0)
    self.byteLimit = byteLimit; self.profile = profile
    passiveByteLimit = profile == .interactive ? byteLimit / 2 : byteLimit
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
      byteCount: entry.cost, entryID: id, resources: self)
  }

  func reserveRaster(pixelWidth: Int, pixelHeight: Int, backingCount: Int = 2) -> RasterReservation? {
    guard (1...16).contains(backingCount),
      let pair = Self.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { return nil }
    let allocation = (pair / 2).multipliedReportingOverflow(by: backingCount)
    guard !allocation.overflow, makeRoom(for: allocation.partialValue, additionalEntry: true, priority: .passive) else { return nil }
    return reserveAllocation(bytes: allocation.partialValue, rasterCount: 1, priority: .passive, physicalOwner: nil)
  }

  /// Buffers and drawable backing compete with images for the same byte pool,
  /// but do not consume an image-cache entry or create another resource owner.
  func reserveDerivedBytes(_ byteCount: Int, priority: SceneAllocationPriority,
    owner: ScenePhysicalOwnerLease? = nil) -> RasterReservation? {
    var identity: ScenePhysicalOwner?
    if let owner {
      guard owner.resources === self, owner.owners.count == 1, let id = owner.owners.first,
        physicalOwners[id]?.priority == priority else { return nil }
      identity = id
    }
    guard byteCount > 0, makeRoom(for: byteCount, additionalEntry: false, priority: priority) else { return nil }
    return reserveAllocation(bytes: byteCount, rasterCount: 0, priority: priority, physicalOwner: identity)
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

  @discardableResult
  func store(_ image: AgentSnapshotImage, for element: AgentElement,
    reservation: RasterReservation? = nil) -> Bool {
    store(image, for: .agent(element), reservation: reservation)
  }
  @discardableResult
  func store(_ image: AgentSnapshotImage, for source: SceneRasterSource,
    reservation: RasterReservation? = nil) -> Bool {
    if let reservation {
      guard !reservation.isReleased, reservation.resources === self else { return false }
      reservation.release()
    }
    guard let raster = Self.rasterDescription(image, source: source),
      makeRoom(for: raster.cost, additionalEntry: true, priority: .passive) else {
      if case .agent(let element) = source {
        record(.init(kind: "resource_limit", elementID: element.id,
          message: "Недостаточно ресурсов для точного снимка"), for: element)
      }
      return false
    }
    // A retained older raster is a distinct accounted entry until its lease ends.
    for id in rasterOwners[source.owner] ?? [] {
      if let entry = entries[id], entry.source == source, entry.retains == 0,
        entry.pixelScale <= raster.scale { removeRaster(id) }
    }
    accessClock &+= 1
    let id = UUID()
    entries[id] = RasterEntry(source: source, image: image, pixelScale: raster.scale,
      cost: raster.cost, access: accessClock, retains: 0)
    rasterOwners[source.owner, default: []].append(id)
    residentBytes += raster.cost; rasterCount = entries.count
    peakAccountedBytes = max(peakAccountedBytes, residentBytes + reservedBytes)
    if case .agent(let element) = source, var diagnostics = diagnosticEntries[element.id], diagnostics.element == element {
      diagnostics.values.removeAll { $0.kind == "resource_limit" }
      diagnosticEntries[element.id] = diagnostics
    }
    changed(source.owner)
    return true
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

  func acquireWebSurface(priority: WebPriority) async throws -> WebSurfaceLease {
    try Task.checkCancellation()
    guard !priority.preparesRaster || maximumBackgroundWebSurfaces > 0 else { throw SceneRenderError.resourceLimit }
    let id = UUID()
    let lease: WebSurfaceLease = try await withTaskCancellationHandler(operation: { () async throws -> WebSurfaceLease in
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSurfaceLease, any Error>) in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        // Every eligible older waiter has already been admitted. Remaining
        // waiters are quota-blocked, so a reserved critical slot must not need
        // a spare position in their full passive queue.
        if canAdmit(priority) {
          continuation.resume(returning: grantWebSurface(id: id, priority: priority))
          return
        }
        guard waiters.count < maximumPendingWebRequests else {
          continuation.resume(throwing: SceneRenderError.resourceLimit); return
        }
        waiterClock &+= 1
        waiters.append(WebWaiter(id: id, priority: priority, order: waiterClock, continuation: continuation))
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
    entry.retains -= 1; entries[id] = entry
  }
  fileprivate func releaseReservation(_ id: UUID) {
    if let allocation = reservations.removeValue(forKey: id) {
      let priority = allocation.physicalOwner.flatMap { physicalOwners[$0]?.priority } ?? allocation.priority
      if priority == .passive { passiveReservedBytes -= allocation.bytes }
      if let id = allocation.physicalOwner, var owner = physicalOwners[id] {
        owner.reservedBytes -= allocation.bytes
        if owner.retains == 0 && owner.reservedBytes == 0 { physicalOwners[id] = nil }
        else { physicalOwners[id] = owner }
      }
      reservedBytes -= allocation.bytes; reservedRasterCount -= allocation.rasterCount
    }
  }
  fileprivate func releaseWebSurface(_ id: UUID) {
    let availability = webAvailability
    guard let priority = activeWebSurfaces.removeValue(forKey: id) else { return }
    activeWebSurfaceCount = activeWebSurfaces.count
    if priority.preparesRaster { activeBackgroundWebSurfaceCount -= 1 }
    if priority > .input { activePassiveWebSurfaceCount -= 1 }
    admitWaiters()
    publishWebAvailability(after: availability)
  }
  fileprivate func updateWebPriority(_ id: UUID, priority: WebPriority) {
    let availability = webAvailability
    guard let previous = activeWebSurfaces[id], previous != priority else { return }
    activeWebSurfaces[id] = priority
    if previous.preparesRaster { activeBackgroundWebSurfaceCount -= 1 }
    if priority.preparesRaster { activeBackgroundWebSurfaceCount += 1 }
    if previous > .input { activePassiveWebSurfaceCount -= 1 }
    if priority > .input { activePassiveWebSurfaceCount += 1 }
    // Existing contacts may temporarily exceed a passive role quota after a
    // handoff. Preserve their leases and admit no new work until below quota.
    admitWaiters()
    publishWebAvailability(after: availability)
  }

  private func canAdmit(_ priority: WebPriority) -> Bool {
    activeWebSurfaces.count < maximumWebSurfaces
      && (!priority.preparesRaster || activeBackgroundWebSurfaceCount < maximumBackgroundWebSurfaces)
      && (priority <= .input || activePassiveWebSurfaceCount < maximumWebSurfaces - reservedInteractiveSlots)
  }
  private func grantWebSurface(id: UUID, priority: WebPriority) -> WebSurfaceLease {
    activeWebSurfaces[id] = priority
    activeWebSurfaceCount = activeWebSurfaces.count
    if priority.preparesRaster { activeBackgroundWebSurfaceCount += 1 }
    if priority > .input { activePassiveWebSurfaceCount += 1 }
    return WebSurfaceLease(id: id, priority: priority, resources: self)
  }
  private func admitWaiters() {
    while let position = waiters.firstIndex(where: { canAdmit($0.priority) }) {
      let waiter = waiters.remove(at: position)
      pendingWebRequestCount = waiters.count
      waiter.continuation.resume(returning: grantWebSurface(id: waiter.id, priority: waiter.priority))
    }
  }
  private func cancelWebRequest(_ id: UUID) {
    let availability = webAvailability
    guard let position = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: position)
    pendingWebRequestCount = waiters.count
    waiter.continuation.resume(throwing: CancellationError())
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
      return a.pixelScale == b.pixelScale ? a.access < b.access : a.pixelScale < b.pixelScale
    }
  }
  private func touchRaster(_ id: UUID) {
    guard var entry = entries[id] else { return }
    accessClock &+= 1; entry.access = accessClock; entries[id] = entry
  }
  private func makeRoom(for cost: Int, additionalEntry: Bool, priority: SceneAllocationPriority,
    passiveReserved: Int? = nil) -> Bool {
    let passive = passiveReserved ?? passiveReservedBytes
    let passiveCost = priority == .passive ? cost : 0
    guard cost >= 0, cost <= byteLimit - reservedBytes,
      passive >= 0, passiveCost <= passiveByteLimit - passive,
      !additionalEntry || maximumRasterCount > 0 else { return refuseRaster(cost: cost, additionalEntry: additionalEntry) }
    let neededCount = additionalEntry ? 1 : 0
    let candidates = entries.filter { $0.value.retains == 0 }.sorted { $0.value.access < $1.value.access }
    let recoverable = candidates.reduce(0) { $0 + $1.value.cost }
    let residentLimit = min(byteLimit - reservedBytes - cost, passiveByteLimit - passive - passiveCost)
    guard residentBytes - recoverable <= residentLimit,
      entries.count - candidates.count + reservedRasterCount + neededCount <= maximumRasterCount else {
      return refuseRaster(cost: cost, additionalEntry: additionalEntry)
    }
    var position = 0
    while residentBytes > residentLimit
      || entries.count + reservedRasterCount + neededCount > maximumRasterCount {
      removeRaster(candidates[position].key); position += 1
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

  nonisolated static func estimatedRasterBytes(pixelWidth: Int, pixelHeight: Int) -> Int? {
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }
    let (rawRow, overflow) = pixelWidth.multipliedReportingOverflow(by: 4)
    guard !overflow, rawRow <= Int.max - 63 else { return nil }
    let row = ((rawRow + 63) / 64) * 64
    let (pixels, rowsOverflow) = row.multipliedReportingOverflow(by: pixelHeight)
    let (cost, copiesOverflow) = pixels.multipliedReportingOverflow(by: 2)
    return rowsOverflow || copiesOverflow ? nil : cost
  }
  private static func rasterDescription(_ image: AgentSnapshotImage,
    source: SceneRasterSource) -> (cost: Int, scale: Double)? {
    #if os(iOS)
      guard let cgImage = image.cgImage else { return nil }
    #else
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    #endif
    let (bytes, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
    let (cost, doubledOverflow) = bytes.multipliedReportingOverflow(by: 2)
    guard !overflow, !doubledOverflow, cost > 0 else { return nil }
    let size: CGSize
    switch source {
    case .agent(let element): size = .init(width: element.frame.width, height: element.frame.height)
    case .document, .composition: size = image.size
    }
    guard size.width > 0, size.height > 0 else { return nil }
    let horizontal = Double(cgImage.width) / size.width
    let vertical = Double(cgImage.height) / size.height
    guard abs(horizontal - vertical) <= max(1 / size.width, 1 / size.height) + 0.000_001 else { return nil }
    return (cost, min(horizontal, vertical))
  }

  /// Every caller uses the same granted executor and receives the exact entry
  /// it prepared. A large composition can release each source after painting it.
  func prepareRaster(_ element: AgentElement, requestedScale: Double = 2,
    permitsPreparation: @MainActor () -> Bool = { true }) async throws -> RasterLease {
    try Task.checkCancellation()
    if let raster = retainRaster(for: element, minimumScale: requestedScale) { return raster }
    let preparation = try await SceneWebRasterPreparation.create(resources: self, permitsPreparation: permitsPreparation)
    defer { preparation.close() }
    return try await preparation.prepare(element, requestedScale: requestedScale, permitsPreparation: permitsPreparation)
  }

}

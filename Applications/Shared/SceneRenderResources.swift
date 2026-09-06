import Foundation
import NotebookCore
import Observation
import SwiftUI
import WebKit

enum SceneRasterSource: Equatable, Sendable {
  case agent(AgentElement)
  case document(id: UUID, token: String)

  fileprivate var owner: RasterOwner {
    switch self {
    case .agent(let element): .agent(element.id)
    case .document(let id, _): .document(id)
    }
  }
}

fileprivate enum RasterOwner: Hashable { case agent(String), document(UUID) }

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

/// A retained image is charged until its final lease ends. Released leases cannot
/// keep an unaccounted strong image reference alive.
@MainActor
final class RasterLease {
  let source: SceneRasterSource
  let pixelScale: Double
  private let entryID: UUID
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
    entryID: UUID, resources: SceneRenderResources) {
    self.source = source; self.pixelScale = pixelScale; retainedImage = image
    self.entryID = entryID; self.resources = resources
  }
  func release() {
    guard let owner = resources else { return }
    resources = nil; retainedImage = nil
    owner.releaseRaster(entryID)
  }
  isolated deinit { release() }
}

@MainActor
final class RasterBatchLease {
  private var rasters: [RasterLease]
  private(set) var isReleased = false
  var count: Int { rasters.count }
  fileprivate init(_ rasters: [RasterLease]) { self.rasters = rasters }
  func image(for element: AgentElement, minimumScale: Double = 0) -> AgentSnapshotImage? {
    guard !isReleased else { return nil }
    return rasters.first { $0.source == .agent(element) }?.image(for: .agent(element), minimumScale: minimumScale)
  }
  func release() {
    guard !isReleased else { return }
    isReleased = true
    for raster in rasters { raster.release() }
    rasters.removeAll()
  }
  isolated deinit { release() }
}

#if os(macOS)
/// A settled SwiftUI tree reads the exact batch acquired by its publisher.
/// The value only carries leases; it neither stores nor discovers other images.
private struct SceneSnapshotRastersKey: EnvironmentKey {
  static let defaultValue: RasterBatchLease? = nil
}
extension EnvironmentValues {
  var sceneSnapshotRasters: RasterBatchLease? {
    get { self[SceneSnapshotRastersKey.self] }
    set { self[SceneSnapshotRastersKey.self] = newValue }
  }
}
#endif

/// Reserves conservative CPU and GPU backing before WebKit allocates a snapshot.
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

/// One admission owner for derived rasters and WebKit execution. Content and
/// interactive state remain in their existing documents; this store is disposable.
@MainActor
@Observable
final class SceneRenderResources {
  static let shared = SceneRenderResources()
  static let didChange = Notification.Name("NotebookSceneRenderResourcesDidChange")
  let byteLimit: Int
  let maximumWebSurfaces: Int
  let maximumBackgroundWebSurfaces: Int
  let maximumPendingWebRequests: Int
  let reservedInteractiveSlots: Int
  private let maximumRasterCount: Int
  private let diagnosticCapacity: Int
  private(set) var residentBytes = 0
  private(set) var reservedBytes = 0
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
  @ObservationIgnored private var reservations: [UUID: Int] = [:]
  @ObservationIgnored private var diagnosticEntries: [String: DiagnosticEntry] = [:]
  @ObservationIgnored private var activeWebSurfaces: [UUID: WebPriority] = [:]
  @ObservationIgnored private var waiters: [WebWaiter] = []
  @ObservationIgnored private var accessClock: UInt64 = 0
  @ObservationIgnored private var waiterClock: UInt64 = 0

  init(byteLimit: Int = 256 * 1024 * 1024, maximumWebSurfaces: Int = 6,
    maximumBackgroundWebSurfaces: Int = 2, maximumPendingWebRequests: Int = 32,
    diagnosticCapacity: Int = 256, maximumRasterCount: Int = 2048, reservedInteractiveSlots: Int = 2) {
    precondition(byteLimit >= 0 && maximumWebSurfaces > 0 && maximumBackgroundWebSurfaces >= 0
      && maximumPendingWebRequests >= 0 && diagnosticCapacity >= 0 && maximumRasterCount >= 0
      && reservedInteractiveSlots >= 0)
    self.byteLimit = byteLimit; self.maximumWebSurfaces = maximumWebSurfaces
    self.maximumBackgroundWebSurfaces = min(maximumWebSurfaces, maximumBackgroundWebSurfaces)
    self.maximumPendingWebRequests = maximumPendingWebRequests
    self.reservedInteractiveSlots = min(reservedInteractiveSlots, maximumWebSurfaces - 1)
    self.diagnosticCapacity = diagnosticCapacity; self.maximumRasterCount = maximumRasterCount
  }

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
    guard let id = matchingRaster(source, minimumScale: minimumScale), var entry = entries[id] else { return nil }
    accessClock &+= 1; entry.access = accessClock; entry.retains += 1; entries[id] = entry
    return RasterLease(source: source, pixelScale: entry.pixelScale, image: entry.image,
      entryID: id, resources: self)
  }

  func reserveRaster(pixelWidth: Int, pixelHeight: Int) -> RasterReservation? {
    guard let cost = Self.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
      makeRoom(for: cost, additionalEntry: true) else { return nil }
    let id = UUID()
    reservations[id] = cost; reservedBytes += cost
    return RasterReservation(id: id, byteCount: cost, resources: self)
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
      makeRoom(for: raster.cost, additionalEntry: true) else {
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
    if let cost = reservations.removeValue(forKey: id) { reservedBytes -= cost }
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
  private func makeRoom(for cost: Int, additionalEntry: Bool) -> Bool {
    guard cost >= 0, cost <= byteLimit - reservedBytes, maximumRasterCount > 0 else { return false }
    let neededCount = additionalEntry ? 1 : 0
    let candidates = entries.filter { $0.value.retains == 0 }.sorted { $0.value.access < $1.value.access }
    let recoverable = candidates.reduce(0) { $0 + $1.value.cost }
    guard residentBytes - recoverable <= byteLimit - reservedBytes - cost,
      entries.count - candidates.count + reservations.count + neededCount <= maximumRasterCount else { return false }
    var position = 0
    while residentBytes > byteLimit - reservedBytes - cost
      || entries.count + reservations.count + neededCount > maximumRasterCount {
      removeRaster(candidates[position].key); position += 1
    }
    return true
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
    switch owner { case .agent(let element): id = element; case .document(let document): id = document }
    NotificationCenter.default.post(name: Self.didChange, object: id)
  }

  static func estimatedRasterBytes(pixelWidth: Int, pixelHeight: Int) -> Int? {
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
    case .document: size = image.size
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
    while !permitsPreparation() {
      try await Task.sleep(for: .milliseconds(30))
    }
    let slot = try await acquireWebSurface(priority: .background)
    defer { slot.release() }
    try Task.checkCancellation()
    // Input may have started while this request waited for its executor.
    guard permitsPreparation() else { throw CancellationError() }
    let coordinator = AgentWebCoordinator(lease: slot, resources: self,
      snapshotPolicy: .exact(scale: requestedScale), onState: { _ in })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let size = CGSize(width: element.frame.width, height: element.frame.height)
    #if os(macOS)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); window.orderOut(nil); window.close() }
    #else
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }) else {
      coordinator.invalidate()
      throw SceneRenderError.snapshotPending(element.id)
    }
    let window = UIWindow(windowScene: scene)
    // Never make the preparation window key: text, Pencil and camera keep the
    // human's window. The viewport is outside the visible scene, not alpha-zero.
    window.frame = CGRect(origin: CGPoint(x: -20_000 - size.width, y: -20_000 - size.height), size: size)
    let controller = UIViewController()
    controller.view.backgroundColor = .clear
    controller.view.addSubview(web)
    web.frame = CGRect(origin: .zero, size: size)
    window.rootViewController = controller
    window.isHidden = false
    defer { coordinator.invalidate(); web.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    #endif
    coordinator.load(element, in: web)
    let deadline = ContinuousClock.now + .seconds(8)
    while true {
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      if let raster = retainRaster(for: element, minimumScale: requestedScale) { return raster }
      if let failure = coordinator.snapshotFailure { throw failure }
      guard ContinuousClock.now < deadline else { throw SceneRenderError.snapshotPending(element.id) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  #if os(macOS)
  /// Existing exact page exports retain their selected entries until publication.
  func prepare(_ elements: [AgentElement], requestedScale: Double = 2) async throws -> RasterBatchLease {
    var retained: [RasterLease] = []
    do {
      for element in elements { retained.append(try await prepareRaster(element, requestedScale: requestedScale)) }
      return RasterBatchLease(retained)
    } catch {
      for raster in retained { raster.release() }
      throw error
    }
  }
  #endif
}

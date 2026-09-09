import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class SceneRenderResourcesTests: XCTestCase {
  @MainActor
  func testInteractiveHalfCountsPinnedRastersAndTemporaryPassiveWorkWithoutReservingTwice() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost * 4, profile: .interactive)
    XCTAssertEqual(resources.passiveByteLimit, cost * 2)
    XCTAssertTrue(resources.store(raster, for: element("shown")))
    let shown = try XCTUnwrap(resources.retainRaster(for: element("shown")))
    let scratch = try XCTUnwrap(resources.reserveDerivedBytes(cost, priority: .passive))
    XCTAssertEqual(resources.residentBytes + resources.passiveReservedBytes, resources.passiveByteLimit)
    XCTAssertNil(resources.reserveDerivedBytes(1, priority: .passive))
    XCTAssertFalse(resources.rasterAdmission.fits(additionalBytes: 1, additionalCount: 0))
    XCTAssertFalse(resources.store(raster, for: element("would-take-input")))
    let pen = try XCTUnwrap(resources.reserveDerivedBytes(cost * 2, priority: .input))
    XCTAssertEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    XCTAssertNil(resources.reserveDerivedBytes(1, priority: .input))
    XCTAssertTrue(shown.image === raster)
    scratch.release(); pen.release(); shown.release()
    XCTAssertEqual(resources.passiveReservedBytes, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testInputCanBorrowUnusedPassiveSpaceButPassiveCannotBorrowTheProtectedHalf() throws {
    let resources = SceneRenderResources(byteLimit: 1_024, profile: .interactive)
    XCTAssertNil(resources.reserveDerivedBytes(513, priority: .passive))
    let input = try XCTUnwrap(resources.reserveDerivedBytes(1_024, priority: .input))
    XCTAssertEqual(resources.reservedBytes, resources.byteLimit)
    XCTAssertEqual(resources.passiveReservedBytes, 0)
    input.release()
    let passive = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .passive))
    let firstContact = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .input))
    passive.release(); firstContact.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testPhysicalHandoffChangesRolesAtomicallyAndSubmittedBytesOutliveTheOwnerLease() throws {
    let resources = SceneRenderResources(byteLimit: 1_024, profile: .interactive)
    let parentID = ScenePhysicalOwner.boardInk(UUID()), childID = ScenePhysicalOwner.boardInk(UUID())
    let parent = try XCTUnwrap(resources.reservePhysicalOwners([parentID], priority: .input))
    let child = try XCTUnwrap(resources.reservePhysicalOwners([childID], priority: .passive))
    let parentBytes = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .input, owner: parent))
    let childBytes = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .passive, owner: child))
    XCTAssertFalse(resources.updatePhysicalPriorities([parentID: .passive]))
    XCTAssertEqual(parent.allocationPriority, .input)
    XCTAssertEqual(child.allocationPriority, .passive)
    XCTAssertEqual(resources.passiveReservedBytes, 512)
    XCTAssertTrue(resources.updatePhysicalPriorities([parentID: .passive, childID: .input]))
    XCTAssertEqual(parent.allocationPriority, .passive)
    XCTAssertEqual(child.allocationPriority, .input)
    XCTAssertEqual(resources.passiveReservedBytes, 512)
    parent.release(); child.release()
    XCTAssertEqual(resources.activePhysicalOwnerCount, 2,
      "Submitted allocations are still real physical owners after UI teardown")
    parentBytes.release()
    XCTAssertEqual(resources.passiveReservedBytes, 0)
    XCTAssertEqual(resources.reservedBytes, 512)
    XCTAssertEqual(resources.activePhysicalOwnerCount, 1)
    childBytes.release()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activePhysicalOwnerCount, 0)
  }

  @MainActor
  func testGeometryBuffersAndRastersHaveOneBudgetButNotOneEntryCount() throws {
    let resources = SceneRenderResources(byteLimit: 1_024, maximumRasterCount: 0)
    let first = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .input))
    let second = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .input))
    XCTAssertEqual(resources.reservedBytes, 1_024)
    XCTAssertNil(resources.reserveDerivedBytes(1, priority: .input))
    XCTAssertNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1))
    first.release()
    let third = try XCTUnwrap(resources.reserveDerivedBytes(512, priority: .input))
    second.release(); third.release()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertNil(resources.reserveDerivedBytes(0, priority: .input))
    XCTAssertNil(resources.reserveDerivedBytes(-1, priority: .input))
    XCTAssertNil(resources.reserveDerivedBytes(Int.max, priority: .input))
  }

  @MainActor
  func testRasterLRUEvictsOnlyTheLeastRecentlyUsedUnretainedImage() throws {
    let raster = image()
    let cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost * 2, profile: .headless)
    let a = element("a"), b = element("b"), c = element("c")
    XCTAssertTrue(resources.store(raster, for: a))
    XCTAssertTrue(resources.store(raster, for: b))
    XCTAssertNotNil(resources.image(for: a))
    XCTAssertTrue(resources.store(raster, for: c))
    XCTAssertNotNil(resources.image(for: a))
    XCTAssertNil(resources.image(for: b))
    XCTAssertNotNil(resources.image(for: c))
    XCTAssertEqual(resources.residentBytes, cost * 2)
    XCTAssertEqual(resources.rasterCount, 2)
  }

  @MainActor
  func testRetainedRasterRefusesNewAllocationUntilItsFinalLeaseEnds() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless)
    let a = element("pinned"), b = element("replacement")
    XCTAssertTrue(resources.store(raster, for: a))
    let first = try XCTUnwrap(resources.retainRaster(for: a))
    let second = try XCTUnwrap(resources.retainRaster(for: a))
    XCTAssertTrue(first.image === raster)
    XCTAssertFalse(resources.store(raster, for: b))
    XCTAssertEqual(resources.residentBytes, cost)
    first.release(); first.release()
    XCTAssertFalse(resources.store(raster, for: b), "A second holder still owns these bytes")
    second.release()
    XCTAssertTrue(resources.store(raster, for: b))
    first.release(); second.release()
    XCTAssertNotNil(resources.image(for: b), "A late duplicate release cannot release a replacement entry")
    XCTAssertNil(resources.image(for: a))
  }

  @MainActor
  func testRasterLeaseDeinitializationReleasesItsPin() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless)
    let a = element("a"), b = element("b")
    XCTAssertTrue(resources.store(raster, for: a))
    var lease = resources.retainRaster(for: a)
    XCTAssertNotNil(lease)
    XCTAssertFalse(resources.store(raster, for: b))
    lease = nil
    XCTAssertTrue(resources.store(raster, for: b))
  }

  @MainActor
  func testReservationChargesBeforeSnapshotAndIsConsumedExactlyOnce() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 16, pixelHeight: 16))
    XCTAssertEqual(resources.reservedBytes, cost)
    XCTAssertNil(resources.reserveRaster(pixelWidth: 16, pixelHeight: 16))
    XCTAssertFalse(resources.store(raster, for: element("unreserved")))
    XCTAssertTrue(resources.store(raster, for: element("reserved"), reservation: reservation))
    XCTAssertTrue(reservation.isReleased)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.residentBytes, cost)
    reservation.release()
    XCTAssertFalse(resources.store(raster, for: element("late"), reservation: reservation))
    XCTAssertEqual(resources.residentBytes, cost)
  }

  @MainActor
  func testOversizedRequestDoesNotEvictAUsefulRaster() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless)
    let source = element("kept")
    XCTAssertTrue(resources.store(raster, for: source))
    XCTAssertNil(resources.reserveRaster(pixelWidth: 1000, pixelHeight: 1000))
    XCTAssertNotNil(resources.image(for: source))
    XCTAssertNil(SceneRenderResources.estimatedRasterBytes(pixelWidth: Int.max, pixelHeight: 16))
  }

  @MainActor
  func testMultisampleInkReservationAccountsEverySimultaneousBacking() throws {
    let resources = SceneRenderResources(byteLimit: 8 * 1024 * 1024, profile: .headless)
    let tile = try XCTUnwrap(resources.reserveRaster(pixelWidth: 512, pixelHeight: 512, backingCount: 8))
    XCTAssertEqual(resources.reservedBytes, resources.byteLimit)
    XCTAssertNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1))
    tile.release()
    XCTAssertEqual(resources.reservedBytes, 0)
    for count in [0, -1, 17, Int.max] {
      XCTAssertNil(resources.reserveRaster(pixelWidth: 512, pixelHeight: 512, backingCount: count))
    }
    XCTAssertNil(resources.reserveRaster(pixelWidth: Int.max, pixelHeight: 512, backingCount: 8))
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testDocumentAndAgentRastersShareTheSameByteBudget() throws {
    let raster = image(), cost = try byteCost(raster)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless)
    let agent = element("agent")
    let document = SceneRasterSource.document(id: UUID(), token: "content-state-page")
    XCTAssertTrue(resources.store(raster, for: agent))
    let held = try XCTUnwrap(resources.retainRaster(for: agent))
    XCTAssertFalse(resources.store(raster, for: document))
    held.release()
    XCTAssertTrue(resources.store(raster, for: document))
    XCTAssertNil(resources.image(for: agent))
    XCTAssertNotNil(resources.image(for: document))
  }

  @MainActor
  func testDisplayLODDoesNotSatisfyAnExactScaleRequest() throws {
    let resources = SceneRenderResources()
    let source = element("scale")
    XCTAssertTrue(resources.store(image(scale: 1), for: source))
    XCTAssertNotNil(resources.image(for: source, minimumScale: 1))
    XCTAssertNil(resources.image(for: source, minimumScale: 2))
    XCTAssertNil(resources.retainRaster(for: source, minimumScale: 2))
    XCTAssertTrue(resources.store(image(scale: 2), for: source))
    let exact = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 2))
    XCTAssertEqual(exact.pixelScale, 2)
    XCTAssertTrue(resources.store(image(scale: 1), for: source))
    XCTAssertTrue(resources.image(for: source) === exact.image,
      "A later display raster cannot downgrade an exact image held by the exporter")
    exact.release()
  }

  @MainActor
  func testFullPassiveQueueLeavesTwoSlotsForTheCurrentPageAndInput() async throws {
    let resources = SceneRenderResources(maximumPendingWebRequests: 1)
    var passive: [WebSurfaceLease] = []
    for _ in 0..<4 { passive.append(try await resources.acquireWebSurface(priority: .neighbor)) }
    let waiting = Task { try await resources.acquireWebSurface(priority: .visible) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    XCTAssertEqual(resources.activePassiveWebSurfaceCount, 4)
    let page = try await resources.acquireWebSurface(priority: .currentPage)
    let input = try await resources.acquireWebSurface(priority: .input)
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    page.release()
    XCTAssertEqual(resources.pendingWebRequestCount, 1,
      "The newly free critical slot is not handed to another passive neighbor")
    passive[0].release()
    let visible = try await waiting.value
    XCTAssertEqual(resources.activePassiveWebSurfaceCount, 4)
    input.release(); visible.release()
    for lease in passive { lease.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testPageRoleChangeRetainsTheSurfaceAndUpdatesAdmissionAccounting() async throws {
    let resources = SceneRenderResources()
    let current = try await resources.acquireWebSurface(priority: .currentPage)
    let identity = current.id
    current.updatePriority(.neighbor)
    XCTAssertEqual(current.id, identity)
    XCTAssertEqual(resources.activePassiveWebSurfaceCount, 1)
    current.updatePriority(.currentPage)
    XCTAssertEqual(resources.activePassiveWebSurfaceCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    current.release()
    current.updatePriority(.background)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 0)
  }

  @MainActor
  func testDiagnosticOwnersAndMessagesAreBounded() {
    let resources = SceneRenderResources(diagnosticCapacity: 2)
    let a = element("a"), b = element("b"), c = element("c")
    for source in [a, b, c] {
      for index in 0..<40 {
        resources.record(.init(kind: "test", elementID: source.id, message: String(index)), for: source)
      }
    }
    XCTAssertEqual(resources.diagnosticOwnerCount, 2)
    XCTAssertTrue(resources.diagnostics(for: [a]).isEmpty)
    XCTAssertEqual(resources.diagnostics(for: [b, c]).count, 64)
    XCTAssertEqual(resources.diagnostics(for: [c]).first?.message, "8")
  }

  @MainActor
  func testWebQueueSharesTwoPreparationSlotsAcrossVisibleAndBackgroundWork() async throws {
    let resources = SceneRenderResources()
    var live: [WebSurfaceLease] = []
    for _ in 0..<2 { live.append(try await resources.acquireWebSurface(priority: .visible)) }
    let background = Task { try await resources.acquireWebSurface(priority: .background) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let visible = Task { try await resources.acquireWebSurface(priority: .visible) }
    try await waitUntil { resources.pendingWebRequestCount == 2 }
    for _ in 0..<2 { live.append(try await resources.acquireWebSurface(priority: .neighbor)) }
    live.append(try await resources.acquireWebSurface(priority: .currentPage))
    live.append(try await resources.acquireWebSurface(priority: .input))
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 2)
    live[4].release()
    XCTAssertEqual(resources.pendingWebRequestCount, 2,
      "A free current-page slot cannot start a third raster executor")
    live[0].release()
    let admitted = try await visible.value
    XCTAssertEqual(resources.activeWebSurfaceCount, 5)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 2)
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    admitted.release()
    let nextBackground = try await background.value
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 2)
    nextBackground.release()
    for lease in live { lease.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testWebQueueUsesPriorityThenFIFOWithoutPreemptingAnOwner() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let active = try await resources.acquireWebSurface(priority: .background)
    var order: [String] = []
    let first = Task { let lease = try await resources.acquireWebSurface(priority: .visible); order.append("first"); return lease }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let second = Task { let lease = try await resources.acquireWebSurface(priority: .visible); order.append("second"); return lease }
    try await waitUntil { resources.pendingWebRequestCount == 2 }
    let input = Task { let lease = try await resources.acquireWebSurface(priority: .input); order.append("input"); return lease }
    try await waitUntil { resources.pendingWebRequestCount == 3 }
    XCTAssertFalse(active.isReleased)
    XCTAssertTrue(order.isEmpty)
    active.release()
    let inputLease = try await input.value
    XCTAssertEqual(order, ["input"])
    inputLease.release()
    let firstLease = try await first.value
    XCTAssertEqual(order, ["input", "first"])
    firstLease.release()
    let secondLease = try await second.value
    XCTAssertEqual(order, ["input", "first", "second"])
    secondLease.release()
  }

  @MainActor
  func testCancelledWaiterLeavesQueueAndDoesNotConsumeAReleasedSlot() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let active = try await resources.acquireWebSurface(priority: .currentPage)
    let cancelled = Task { try await resources.acquireWebSurface(priority: .input) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("Cancelled waiter was admitted") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    let next = Task { try await resources.acquireWebSurface(priority: .visible) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    active.release(); active.release()
    let replacement = try await next.value
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    active.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 1, "Old release does not free a newly assigned slot")
    replacement.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testCancellationRacingWithAdmissionReturnsTheSlot() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let active = try await resources.acquireWebSurface(priority: .currentPage)
    let pending = Task { try await resources.acquireWebSurface(priority: .input) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    pending.cancel()
    active.release()
    do { _ = try await pending.value; XCTFail("Cancelled admission returned a lease") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testQueueRefusesBeyondItsPendingBudget() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumPendingWebRequests: 1)
    let active = try await resources.acquireWebSurface(priority: .input)
    let waiting = Task { try await resources.acquireWebSurface(priority: .visible) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    do { _ = try await resources.acquireWebSurface(priority: .background); XCTFail("Queue exceeded its capacity") }
    catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    waiting.cancel()
    _ = try? await waiting.value
    active.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testWebLeaseDeinitializationReturnsItsSlot() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    var lease: WebSurfaceLease? = try await resources.acquireWebSurface(priority: .input)
    XCTAssertNotNil(lease)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    lease = nil
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testWebRetryEpochChangesOnlyWhenAdmissionActuallyBecomesAvailable() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumPendingWebRequests: 1)
    let held = try await resources.acquireWebSurface(priority: .input)
    let waiting = Task { try await resources.acquireWebSurface(priority: .visible) }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let fullEpoch = resources.webAdmissionGeneration
    do { _ = try await resources.acquireWebSurface(priority: .visible); XCTFail("Full queue admitted another request") }
    catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertEqual(resources.webAdmissionGeneration, fullEpoch)
    XCTAssertTrue(resources.store(image(), for: element("not-a-web-capacity-event")))
    XCTAssertEqual(resources.webAdmissionGeneration, fullEpoch,
      "Raster activity must not restart refused web demands")
    waiting.cancel()
    _ = try? await waiting.value
    XCTAssertGreaterThan(resources.webAdmissionGeneration, fullEpoch,
      "Cancellation opens one previously full queue position")
    let queueEpoch = resources.webAdmissionGeneration
    held.release()
    XCTAssertGreaterThan(resources.webAdmissionGeneration, queueEpoch)
    let releasedEpoch = resources.webAdmissionGeneration
    held.release(); held.updatePriority(.background)
    XCTAssertEqual(resources.webAdmissionGeneration, releasedEpoch,
      "Duplicate release and late role change do not create retry loops")
  }

  @MainActor
  private func image(scale: CGFloat = 1) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale; format.opaque = true; format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
      UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
  }
  private func element(_ id: String) -> AgentElement {
    AgentElement(id: id, kind: .web, frame: .init(x: 0, y: 0, width: 16, height: 16),
      source: "Synthetic resource fixture", html: "<svg viewBox='0 0 16 16'/>")
  }
  private func byteCost(_ image: UIImage) throws -> Int {
    let cgImage = try XCTUnwrap(image.cgImage)
    return cgImage.bytesPerRow * cgImage.height * 2
  }
  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(condition(), "The bounded resource queue did not reach the expected state")
  }
}

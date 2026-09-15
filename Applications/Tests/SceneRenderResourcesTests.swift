import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class SceneRenderResourcesTests: XCTestCase {
  @MainActor
  func testFourVisibleProgramsAreInputOwnersNotPassivePreparation() async throws {
    let resources = SceneRenderResources()
    var programs: [WebSurfaceLease] = []
    defer { programs.forEach { $0.release() } }
    for _ in 0..<4 {
      programs.append(try await resources.acquireWebSurface(priority: .liveProgram,
        deadline: .now + .milliseconds(250)))
    }
    let preparation = try await resources.acquireWebSurface(priority: .background,
      deadline: .now + .milliseconds(250))
    defer { preparation.release() }
    let input = try await resources.acquireWebSurface(priority: .input,
      deadline: .now + .milliseconds(250))
    defer { input.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    XCTAssertEqual(resources.activePassiveWebSurfaceCount, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 1)
  }

  @MainActor
  func testOptionalSynchronousAllocationsCannotPassAnAcceptedDerivedStage() async throws {
    let resources = SceneRenderResources(byteLimit: 10_000, profile: .interactive)
    let held = try XCTUnwrap(resources.reserveDerivedBytes(4_000, priority: .passive))
    let waiting = Task { try await resources.acquirePassiveDerivedBytes(4_500) }
    defer { held.release(); waiting.cancel() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    XCTAssertNil(resources.reserveDerivedBytes(500, priority: .passive))
    XCTAssertNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1))
    XCTAssertNil(resources.reserveRasterBatch([(1, 1)]))
    held.release()
    let granted = try await waiting.value
    granted.release()
    XCTAssertNotNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1))
  }

  @MainActor
  func testCompleteRasterCaptureKeepsEveryGrantedSlotThroughPublication() async throws {
    let image = image(), cost = try byteCost(image)
    let resources = SceneRenderResources(byteLimit: cost * 3, profile: .headless, maximumRasterCount: 3)
    let grants = try XCTUnwrap(resources.reserveRasterBatch([(16, 16), (16, 16), (16, 16)]))
    defer { grants.forEach { $0.release() } }
    XCTAssertEqual(resources.rasterAdmission.reservedCount, 3)
    XCTAssertEqual(resources.reservedBytes, cost * 3)
    XCTAssertNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1))
    let waiting = Task { try await resources.acquirePassiveDerivedBytes(cost) }
    defer { waiting.cancel() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    var rasters: [RasterLease] = []
    defer { rasters.forEach { $0.release() } }
    for (index, grant) in grants.enumerated() {
      let source = SceneRasterSource.document(id: UUID(), token: "granted-\(index)")
      rasters.append(try XCTUnwrap(resources.storeAndRetain(image, for: source, reservation: grant)))
      XCTAssertEqual(resources.rasterAdmission.heldBytes, cost * 3)
      XCTAssertEqual(resources.rasterAdmission.pinnedCount + resources.rasterAdmission.reservedCount, 3)
    }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    rasters.removeLast().release()
    let stage = try await waiting.value
    stage.release()
  }

  @MainActor
  func testPublicationObserversCannotReclaimTheIncomingRetainedRaster() throws {
    let image = image(), cost = try byteCost(image)
    let resources = SceneRenderResources(byteLimit: cost, profile: .headless, maximumRasterCount: 1)
    let source = SceneRasterSource.document(id: UUID(), token: "publication")
    let grant = try XCTUnwrap(resources.reserveRaster(pixelWidth: 16, pixelHeight: 16))
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
          XCTAssertNil(resources.reserveRaster(pixelWidth: 16, pixelHeight: 16),
            "Publication already owns the returned image, even before observers return")
        }
      }
    defer { NotificationCenter.default.removeObserver(observer); grant.release() }
    let raster = try XCTUnwrap(resources.storeAndRetain(image, for: source, reservation: grant))
    defer { raster.release() }
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, cost)
  }

  @MainActor
  func testMemoryReclamationAddressesOneCheapOwnerAndKeepsCanonicalWork() throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let canonical = try XCTUnwrap(resources.reserveDerivedBytes(200, priority: .passive))
    let preview = try XCTUnwrap(resources.reserveDerivedBytes(200, priority: .passive))
    let canonicalID = UUID(), previewID = UUID()
    var released: [String] = []
    let first = resources.registerReclamationOwner { [.init(id: canonicalID, bytes: 200, rasterCount: 0,
      value: .canonicalLayout, distance: 0, restorationMilliseconds: 300,
      release: { released.append("canonical"); canonical.release(); return nil })] }
    let second = resources.registerReclamationOwner { preview.isReleased ? [] : [.init(id: previewID, bytes: 200, rasterCount: 0,
      value: .neighbour, distance: 2, restorationMilliseconds: 10,
      release: { released.append("preview"); preview.release(); return nil })] }
    defer { resources.unregisterReclamationOwner(first); resources.unregisterReclamationOwner(second); canonical.release(); preview.release() }
    let admitted = try XCTUnwrap(resources.reserveDerivedBytes(200, priority: .passive))
    defer { admitted.release() }
    XCTAssertEqual(released, ["preview"])
    XCTAssertFalse(canonical.isReleased); XCTAssertEqual(resources.reservedBytes, 400)
  }

  @MainActor
  func testMemoryReleaseWaitsForTheActualOperationWithoutEvictingAnotherOwner() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let first = try XCTUnwrap(resources.reserveDerivedBytes(200, priority: .passive))
    let second = try XCTUnwrap(resources.reserveDerivedBytes(200, priority: .passive))
    let firstID = UUID(), secondID = UUID()
    var finish: CheckedContinuation<Void, Never>?
    var released: [UUID] = []
    let owner = resources.registerReclamationOwner {
      [first, second].filter { !$0.isReleased }.map { (reservation: RasterReservation) -> SceneResourceReclamationCandidate in
        .init(id: reservation === first ? firstID : secondID, bytes: 200, rasterCount: 0, value: .neighbour,
          distance: reservation === first ? 2 : 1, restorationMilliseconds: 1,
          release: {
            released.append(reservation === first ? firstID : secondID)
            return Task { @MainActor in
              await withCheckedContinuation { finish = $0 }
              reservation.release()
            }
          })
      }
    }
    var granted = false
    let request = Task { @MainActor in
      let result = try await resources.acquirePassiveDerivedBytes(200); granted = true; return result
    }
    defer { request.cancel(); finish?.resume(); finish = nil; first.release(); second.release(); resources.unregisterReclamationOwner(owner) }
    try await waitUntil { finish != nil && resources.pendingDerivedRequestCount == 1 }
    XCTAssertEqual(released, [firstID]); XCTAssertFalse(granted)
    XCTAssertEqual(resources.reservedBytes, 400)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(released, [firstID])
    finish?.resume(); finish = nil
    let result = try await request.value
    defer { result.release() }
    XCTAssertTrue(granted); XCTAssertFalse(second.isReleased)
    XCTAssertEqual(released, [firstID]); XCTAssertEqual(resources.reservedBytes, 400)
  }

  @MainActor
  func testSmallNewRequestsCannotConsumeCapacityAheadOfALargeAcceptedStage() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(300, priority: .passive))
    var order: [String] = []
    let large = Task { @MainActor in
      let value = try await resources.acquirePassiveDerivedBytes(400); order.append("large"); return value
    }
    defer { blocker.release(); large.cancel() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    let small = Task { @MainActor in
      let value = try await resources.acquirePassiveDerivedBytes(100); order.append("small"); return value
    }
    defer { small.cancel() }
    try await waitUntil { resources.pendingDerivedRequestCount == 2 }
    XCTAssertTrue(order.isEmpty)
    blocker.release()
    let a = try await large.value, b = try await small.value
    defer { a.release(); b.release() }
    XCTAssertEqual(order, ["large", "small"])
    XCTAssertEqual(resources.reservedBytes, 500)
  }

  @MainActor
  func testIdleExecutorReclamationTargetsOneOwnerAndWaitsForItsPhysicalBorrow() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 2, maximumBackgroundWebSurfaces: 2,
      maximumPendingWebRequests: 2, reservedInteractiveSlots: 0)
    let first = try await resources.acquireWebSurface(priority: .visible)
    let second = try await resources.acquireWebSurface(priority: .visible)
    let physicalCall = try first.borrow()
    var retired: [UUID] = []
    first.offerIdleReclamation { retired.append(first.id); first.release() }
    second.offerIdleReclamation { retired.append(second.id); second.release() }
    var admitted = false
    let request = Task { @MainActor in
      let lease = try await resources.acquireWebSurface(priority: .currentPage)
      admitted = true; return lease
    }
    defer { request.cancel(); physicalCall.release(); first.release(); second.release() }
    for _ in 0..<100 where resources.pendingWebRequestCount == 0 { await Task.yield() }
    XCTAssertEqual(retired, [first.id])
    XCTAssertEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertFalse(admitted)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(retired, [first.id], "A finishing owner must not cause fan-out eviction")
    physicalCall.release()
    let current = try await request.value
    defer { current.release() }
    XCTAssertTrue(admitted); XCTAssertFalse(second.isReleased)
    XCTAssertEqual(retired, [first.id]); XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testStageAdmissionTransfersWithoutLettingAQueuedConsumerTakeItsCapacity() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let admitted = try XCTUnwrap(resources.reserveDerivedBytes(500, priority: .passive))
    var competitorStarted = false
    let competitor = Task { @MainActor in
      let reservation = try await resources.acquirePassiveDerivedBytes(100)
      competitorStarted = true; return reservation
    }
    defer { competitor.cancel(); admitted.release() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    let stage = try XCTUnwrap(resources.splitPassiveDerivedReservation(admitted, bytes: 200))
    defer { stage.release() }
    XCTAssertEqual(admitted.byteCount, 300)
    XCTAssertEqual(resources.reservedBytes, 500)
    XCTAssertTrue(resources.transferPassiveDerivedReservation(admitted, to: stage, bytes: 300))
    XCTAssertTrue(admitted.isReleased)
    XCTAssertEqual(stage.byteCount, 500)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(competitorStarted, "Handoff must never publish its admitted bytes as available")
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    XCTAssertEqual(resources.reservedBytes, 500)
    XCTAssertEqual(resources.peakAccountedBytes, 500)
    stage.release()
    let next = try await competitor.value
    XCTAssertTrue(competitorStarted)
    XCTAssertEqual(resources.reservedBytes, 100)
    next.release(); admitted.release(); stage.release()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
  }

  @MainActor
  func testStageTransferRejectsForeignReleasedAndSelfReservationsWithoutChangingEitherPool() throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let other = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let donor = try XCTUnwrap(resources.reserveDerivedBytes(300, priority: .passive))
    let receiver = try XCTUnwrap(other.reserveDerivedBytes(200, priority: .passive))
    defer { donor.release(); receiver.release() }
    XCTAssertFalse(resources.transferPassiveDerivedReservation(donor, to: receiver, bytes: 100))
    XCTAssertNil(resources.splitPassiveDerivedReservation(donor, bytes: 301))
    XCTAssertFalse(resources.transferPassiveDerivedReservation(donor, to: donor, bytes: 100))
    XCTAssertEqual(resources.reservedBytes, 300)
    XCTAssertEqual(other.reservedBytes, 200)
    receiver.release()
    XCTAssertFalse(resources.transferPassiveDerivedReservation(donor, to: receiver, bytes: 100))
    XCTAssertEqual(donor.byteCount, 300)
  }

  @MainActor
  func testDerivedReservationTransferAdmitsOnlyGrowthAndNeverDropsItsExistingCharge() throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let staging = try XCTUnwrap(resources.reserveDerivedBytes(400, priority: .passive))
    defer { staging.release() }
    XCTAssertTrue(resources.resizePassiveDerivedReservation(staging, to: 450),
      "Only fifty additional bytes are needed, not another full 450-byte reservation")
    XCTAssertEqual(staging.byteCount, 450)
    XCTAssertEqual(resources.reservedBytes, 450)
    XCTAssertFalse(resources.resizePassiveDerivedReservation(staging, to: 600))
    XCTAssertEqual(staging.byteCount, 450)
    XCTAssertEqual(resources.reservedBytes, 450, "Failed growth preserves the old materialized packet charge")
    XCTAssertTrue(resources.resizePassiveDerivedReservation(staging, to: 100))
    XCTAssertEqual(staging.byteCount, 100)
    XCTAssertEqual(resources.reservedBytes, 100)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, 500)
    staging.release(); staging.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testRequiredDerivedBytesWaitForSufficientCapacityWithoutRepeatingRefusals() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let large = try XCTUnwrap(resources.reserveDerivedBytes(400, priority: .passive))
    let small = try XCTUnwrap(resources.reserveDerivedBytes(99, priority: .passive))
    var admitted = false
    let request = Task { @MainActor in
      let reservation = try await resources.acquirePassiveDerivedBytes(200)
      admitted = true; return reservation
    }
    defer { request.cancel(); large.release(); small.release() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    let refusal = try XCTUnwrap(resources.lastRasterRefusal).generation
    XCTAssertEqual(resources.reservedBytes, 499, "Queued work owns no unadmitted byte buffer")
    small.release()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(admitted)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal,
      "An insufficient release cannot rerun the same failed allocation")
    large.release()
    let reservation = try await request.value
    defer { reservation.release() }
    XCTAssertTrue(admitted)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.reservedBytes, 200)
    XCTAssertEqual(resources.passiveReservedBytes, 200)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, 500,
      "The interactive half of the same pool is never borrowed")
  }

  @MainActor
  func testCancellingADerivedAdmissionReleasesOnlyThatWaiterBeforeAnotherRequestRecovers() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(500, priority: .passive))
    let cancelled = Task { try await resources.acquirePassiveDerivedBytes(200) }
    let survivor = Task { try await resources.acquirePassiveDerivedBytes(200) }
    defer { cancelled.cancel(); survivor.cancel(); blocker.release() }
    try await waitUntil { resources.pendingDerivedRequestCount == 2 }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("Cancelled work received a reservation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    XCTAssertEqual(resources.reservedBytes, 500)
    blocker.release()
    let reservation = try await survivor.value
    defer { reservation.release() }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.reservedBytes, 200)
  }

  @MainActor
  func testImpossibleDerivedSizeAndFullAdmissionQueueFailExplicitly() async throws {
    let resources = SceneRenderResources(byteLimit: 1_000, profile: .interactive, maximumPendingWebRequests: 1)
    do { _ = try await resources.acquirePassiveDerivedBytes(501); XCTFail("A request larger than its whole budget must fail") }
    catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(500, priority: .passive))
    let waiting = Task { try await resources.acquirePassiveDerivedBytes(200) }
    defer { waiting.cancel(); blocker.release() }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    do { _ = try await resources.acquirePassiveDerivedBytes(100); XCTFail("The bounded queue cannot grow indefinitely") }
    catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    waiting.cancel(); _ = try? await waiting.value
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.reservedBytes, 500)
  }

  @MainActor
  func testDocumentProgramSharesSourceExclusivityButNotUnrelatedDocumentOrBoardIdentity() async throws {
    let resources = SceneRenderResources(), documentID = UUID()
    let old = try await resources.acquireDocumentProgramSurface(priority: .liveProgram,
      documentID: documentID, blockID: "same-local-id")
    let submitted = try old.borrow()
    old.release()
    var replacementStarted = false
    let replacement = Task { @MainActor in
      let value = try await resources.acquireDocumentProgramSurface(priority: .input,
        documentID: documentID, blockID: "same-local-id", deadline: .now + .seconds(3))
      replacementStarted = true
      return value
    }
    defer { replacement.cancel(); submitted.release(); old.release() }
    for _ in 0..<100 where resources.pendingWebRequestCount == 0 { await Task.yield() }
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    let otherDocument = try await resources.acquireDocumentProgramSurface(priority: .input,
      documentID: UUID(), blockID: "same-local-id")
    let board = try await resources.acquireWebSurface(priority: .input,
      source: .board(boardID: documentID, elementID: "same-local-id"))
    defer { otherDocument.release(); board.release() }
    XCTAssertFalse(replacementStarted)
    XCTAssertEqual(resources.activeWebSurfaceCount, 3)
    submitted.release()
    let current = try await replacement.value
    defer { current.release() }
    XCTAssertTrue(replacementStarted)
    XCTAssertEqual(resources.activeWebSurfaceCount, 3)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testOneSourceExecutorWaitsForItsActualSubmittedBorrowWhileUnrelatedInputProceeds() async throws {
    let resources = SceneRenderResources()
    let source = InteractiveElementReference.board(boardID: UUID(), elementID: "shared-program")
    let raster = try await resources.acquireWebSurface(priority: .background, source: source)
    let submitted = try raster.borrow()
    var hasPromoted = false
    let promoted = Task { @MainActor in
      let lease = try await resources.acquireWebSurface(priority: .input, source: source, deadline: .now + .seconds(3))
      hasPromoted = true
      return lease
    }
    defer { promoted.cancel(); submitted.release(); raster.release() }
    for _ in 0..<100 where resources.pendingWebRequestCount == 0 { await Task.yield() }
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    let other = try await resources.acquireWebSurface(priority: .input,
      source: .board(boardID: UUID(), elementID: "unrelated"))
    defer { other.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertFalse(hasPromoted)
    raster.release()
    await Task.yield()
    XCTAssertFalse(hasPromoted, "Dismantling does not end a submitted WebKit operation")
    submitted.release()
    let input = try await promoted.value
    defer { input.release() }
    XCTAssertTrue(hasPromoted)
    XCTAssertEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testSourceAdmissionDeadlineTerminatesOnlyItsWaiterAndLeavesNoQueueEntry() async throws {
    let resources = SceneRenderResources()
    let source = InteractiveElementReference.page(pageID: UUID(), elementID: "occupied")
    let owner = try await resources.acquireWebSurface(priority: .liveProgram, source: source)
    defer { owner.release() }
    do {
      let duplicate = try await resources.acquireWebSurface(priority: .input, source: source,
        deadline: .now + .milliseconds(50))
      duplicate.release()
      XCTFail("A second executor cannot enter the same physical source")
    } catch {
      XCTAssertTrue(error is SceneRenderError)
    }
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertFalse(owner.isReleased)
  }

  @MainActor
  func testVisibleProgramsCannotPermanentlyOccupyTheRasterExecutor() async throws {
    let resources = SceneRenderResources()
    var programs: [WebSurfaceLease] = []
    for _ in 0..<5 { programs.append(try await resources.acquireWebSurface(priority: .liveProgram)) }
    defer { programs.forEach { $0.release() } }
    let sixth = Task { try await resources.acquireWebSurface(priority: .liveProgram) }
    defer { sixth.cancel() }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let preparation = try await resources.acquireWebSurface(priority: .background)
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    preparation.release()
    XCTAssertEqual(resources.pendingWebRequestCount, 1, "A permanent owner cannot take the transient executor")
    programs.removeLast().release()
    let replacement = try await sixth.value
    replacement.release()
  }

  @MainActor
  func testRasterEvictionReleasesItsSharedLayoutBeforeReadmittingDerivedBytes() throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024, profile: .headless)
    let geometry = WorkspaceItemGeometry.document(.a4)
    var layout: DocumentLayoutRecord? = try DocumentLayoutRecord(receipt: [
      "sourceKey": "source", "layoutScope": "source", "layoutCanonical": true, "anchors": [], "reading": [], "pageCount": 1,
      "width": geometry.width, "height": geometry.height, "regions": []
    ] as NSDictionary, sourceKey: "source", blockIDs: [], geometry: geometry,
      reservation: try XCTUnwrap(resources.reserveDerivedBytes(48 * 1024, priority: .passive)))
    weak let measured = layout
    let source = SceneRasterSource.document(id: UUID(), token: "measured")
    XCTAssertTrue(resources.store(image(), for: source, documentLayout: layout))
    let reader = try XCTUnwrap(resources.retainRaster(for: source))
    layout = nil
    XCTAssertNotNil(measured)
    XCTAssertNil(resources.reserveDerivedBytes(32 * 1024, priority: .passive),
      "A displayed raster protects its measured layout, not just the image")
    XCTAssertNotNil(resources.image(for: source))
    reader.release()
    let replacement = try XCTUnwrap(resources.reserveDerivedBytes(32 * 1024, priority: .passive))
    XCTAssertNil(measured, "The cache cannot leave a detached layout reservation behind")
    XCTAssertNil(resources.image(for: source))
    XCTAssertEqual(resources.reservedBytes, replacement.byteCount)
    replacement.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testSubmittedWebBorrowDefersAdmissionAfterTheMountReleases() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .currentPage)
    let borrow = try lease.borrow()
    lease.release(); lease.release()
    XCTAssertTrue(lease.isReleased)
    XCTAssertThrowsError(try lease.borrow())
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    let waiting = Task { try await resources.acquireWebSurface(priority: .currentPage) }
    for _ in 0..<100 where resources.pendingWebRequestCount == 0 { await Task.yield() }
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    borrow.release(); borrow.release()
    let next = try await waiting.value
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    next.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testAbandonedBorrowReturnsTheWebSlotExactlyOnce() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .currentPage)
    var borrow: WebSurfaceBorrow? = try lease.borrow()
    XCTAssertNotNil(borrow)
    lease.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    borrow = nil
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    lease.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

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
  func testRetainingAnOldReceiptCannotReplaceANewerEqualDensityCapture() throws {
    let resources = SceneRenderResources(), source = element("same-program-state")
    let previousPixels = image(color: .red), currentPixels = image(color: .green)
    XCTAssertTrue(resources.store(previousPixels, for: source))
    let previous = try XCTUnwrap(resources.retainRaster(for: source))
    defer { previous.release() }
    XCTAssertTrue(resources.store(currentPixels, for: source))
    let current = try XCTUnwrap(resources.retainRaster(for: source))
    defer { current.release() }
    XCTAssertNotEqual(current.entryID, previous.entryID)
    XCTAssertEqual(current.pixelScale, previous.pixelScale)
    let cost = resources.residentBytes
    for _ in 0..<3 {
      let immutableReceipt = try XCTUnwrap(previous.retainedCopy())
      defer { immutableReceipt.release() }
      XCTAssertTrue(immutableReceipt.image === previousPixels,
        "An old immutable receipt still retains its own actual pixels")
      let selected = try XCTUnwrap(resources.retainRaster(for: source))
      defer { selected.release() }
      XCTAssertEqual(selected.entryID, current.entryID,
        "Touching an older receipt changes its eviction priority, not which capture is newest")
      XCTAssertTrue(selected.image === currentPixels)
      XCTAssertTrue(resources.image(for: source) === currentPixels)
      XCTAssertEqual(resources.residentBytes, cost, "Borrowing either version cannot allocate another bitmap")
    }
  }

  @MainActor
  func testRasterPublicationOrderNeverMixesStateSourceOrCropVersions() throws {
    let resources = SceneRenderResources(), source = element("versioned-program")
    let changedState = source.updating(state: .number(1))
    let changedSource = AgentElement(id: source.id, kind: source.kind, frame: source.frame,
      source: "Changed program", html: "<svg viewBox='0 0 16 16'><circle r='4'/></svg>")
    let crop = PageRect(x: 0, y: 0, width: 8, height: 8)
    let a = image(color: .red), b = image(color: .green), c = image(color: .blue), d = image(color: .yellow)
    XCTAssertTrue(resources.store(a, for: source))
    XCTAssertTrue(resources.store(b, for: changedState))
    XCTAssertTrue(resources.store(c, for: changedSource))
    XCTAssertTrue(resources.store(d, for: .agentRegion(source, crop)))
    XCTAssertTrue(resources.image(for: source) === a)
    XCTAssertTrue(resources.image(for: changedState) === b)
    XCTAssertTrue(resources.image(for: changedSource) === c)
    XCTAssertTrue(resources.image(for: .agentRegion(source, crop)) === d)
    XCTAssertNil(resources.image(for: .agentRegion(changedState, crop)))
    XCTAssertNil(resources.image(for: .agentRegion(source, .init(x: 8, y: 8, width: 8, height: 8))))
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
  private func image(scale: CGFloat = 1, color: UIColor = .systemBlue) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale; format.opaque = true; format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
      color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
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

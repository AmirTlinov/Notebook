import AppKit
import CryptoKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentTargetSnapshotPreparationTests: XCTestCase {
  func testHeadlessPressureWithdrawsOptionalQueueButKeepsRequiredPreparation() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let blocker = try BackgroundProgram(resources: resources)
    defer { blocker.close() }
    try await waitUntil { blocker.coordinator.ready }
    let optionalDocument = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "body", html: "Optional current view", height: 100)])
    let requiredDocument = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "body", html: "Accepted target", height: 100)])
    let optionalState = DocumentStateJournal(id: optionalDocument.id, actor: UUID())
    let requiredState = DocumentStateJournal(id: requiredDocument.id, actor: UUID())
    var optionalRaster: RasterLease?, requiredRaster: RasterLease?
    var optionalFinished = false, requiredFinished = false
    let optional = Task { @MainActor in
      defer { optionalFinished = true }
      optionalRaster = try await DocumentSnapshotCache.shared.prepare(document: optionalDocument, state: optionalState,
        pageIndex: 0, resources: resources, programStore: blocker.store, pixelWidth: 160, purpose: { .optional })
    }
    let required = Task { @MainActor in
      defer { requiredFinished = true }
      requiredRaster = try await DocumentSnapshotCache.shared.prepare(document: requiredDocument, state: requiredState,
        pageIndex: 0, resources: resources, programStore: blocker.store, pixelWidth: 160)
    }
    defer { optional.cancel(); required.cancel() }
    addTeardownBlock { @MainActor in
      optional.cancel(); required.cancel(); blocker.close()
      _ = await optional.result; _ = await required.result
      optionalRaster?.release(); requiredRaster?.release()
    }
    try await waitUntil { resources.pendingWebRequestCount == 2 }
    resources.handleMemoryPressure(.warning)
    // Pool admission must withdraw the optional queue place in this actor turn,
    // before the caller's deferred invalidation could reach the coordinator.
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 1)
    try await waitUntil { optionalFinished }
    do { try await optional.value; XCTFail("Optional pressure returned a new document raster") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertNil(optionalRaster)
    XCTAssertFalse(requiredFinished)
    blocker.close()
    try await waitUntil { requiredFinished }
    try await required.value
    let raster = try XCTUnwrap(requiredRaster)
    XCTAssertEqual(raster.source, .document(id: requiredDocument.id,
      token: DocumentSnapshotCache.token(document: requiredDocument, state: requiredState, pageIndex: 0)))
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    try attach(["fixture": "headless-required-versus-optional-pressure", "optionalFinished": optionalFinished,
      "requiredFinished": requiredFinished, "requiredRaster": requiredRaster != nil,
      "pendingWeb": resources.pendingWebRequestCount], name: "headless-pressure-admission-result")
  }

  func testPressureWithdrawsQueuedOptionalPaperAndKeepsItsPromotedDerivedAdmission() async throws {
    let mib = 1024 * 1024
    let resources = SceneRenderResources(byteLimit: 64 * mib)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "Derived paper admission")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertLessThan(artifact.pdf.count, mib)
    let sourceCharge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
    let source = DocumentPrintedSource(artifact: artifact, pdf: .init(artifact.pdf), reservation: sourceCharge,
      lineIndices: [:], slots: [:])
    let page = DocumentPrintedPage(source: source, pageIndex: 0, width: 1024, height: 1408)
    let sourceKey = "derived-pressure-" + document.id.uuidString
    let baseline = resources.reservedBytes
    let pinnedSource = SceneRasterSource.document(id: UUID(), token: "pinned-sixty-mib")
    func pinnedImage() throws -> NSImage {
      let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 3840, bitsPerComponent: 8,
        bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 2048, height: 3840))
      return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .init(width: 2048, height: 3840))
    }
    XCTAssertTrue(resources.store(try pinnedImage(), for: pinnedSource))
    let pinned = try XCTUnwrap(resources.retainRaster(for: pinnedSource))
    XCTAssertEqual(pinned.accountedByteCount, 60 * mib)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 60 * mib)
    var optionalFinished = false, requiredFinished = false, optionalWaiting = false
    var optionalPaper: DocumentPaperRaster?, promotedPaper: DocumentPaperRaster?, requiredCharge: RasterReservation?
    var promotedPurpose = ScenePreparationPurpose.optional
    var required: Task<Void, any Error>?, promoted: Task<Void, any Error>?
    let optional = Task { @MainActor in
      defer { optionalFinished = true }
      optionalPaper = try await DocumentPaperRaster.prepare(page: page, sourceKey: sourceKey, pixelWidth: 1024,
        resources: resources, purpose: { .optional }, waits: { optionalWaiting = $0 })
    }
    defer { optional.cancel(); required?.cancel(); promoted?.cancel(); pinned.release() }
    addTeardownBlock { @MainActor in
      optional.cancel(); required?.cancel(); promoted?.cancel(); pinned.release()
      _ = await optional.result
      if let required { _ = await required.result }
      if let promoted { _ = await promoted.result }
      requiredCharge?.release(); optionalPaper = nil; promotedPaper = nil
    }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 && optionalWaiting }
    required = Task { @MainActor in
      defer { requiredFinished = true }
      requiredCharge = try await resources.acquirePassiveDerivedBytes(mib)
    }
    try await waitUntil { resources.pendingDerivedRequestCount == 2 }
    XCTAssertTrue(optionalWaiting); XCTAssertFalse(requiredFinished)
    XCTAssertEqual(resources.reservedBytes, baseline, "Queued paper consumes no physical credit")
    resources.handleMemoryPressure(.warning)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0, "Optional 11 MiB cannot hold required 1 MiB behind its FIFO position")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 60 * mib)
    try await waitUntil { optionalFinished && requiredFinished }
    do { try await optional.value; XCTFail("Pressure admitted the unneeded paper") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    let requiredTask = try XCTUnwrap(required)
    try await requiredTask.value
    XCTAssertNil(optionalPaper); XCTAssertFalse(optionalWaiting)
    XCTAssertEqual(requiredCharge?.byteCount, mib)
    XCTAssertEqual(resources.reservedBytes, baseline + mib)
    let unopened = await source.pdf.openedDocumentCount()
    XCTAssertEqual(unopened, 0, "Revoked queued paper never starts the PDF/image worker")
    requiredCharge?.release(); requiredCharge = nil

    resources.handleMemoryPressure(.normal)
    promoted = Task { @MainActor in
      promotedPaper = try await DocumentPaperRaster.prepare(page: page, sourceKey: sourceKey, pixelWidth: 1024,
        resources: resources, purpose: { promotedPurpose }, waits: { _ in })
    }
    try await waitUntil { resources.pendingDerivedRequestCount == 1 }
    promotedPurpose = .required
    resources.handleMemoryPressure(.warning)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1, "The same queued paper reads its accepted promotion live")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 60 * mib)
    XCTAssertEqual(resources.reservedBytes, baseline)
    XCTAssertNil(promotedPaper)
    pinned.release()
    let promotedTask = try XCTUnwrap(promoted)
    try await promotedTask.value
    XCTAssertFalse(resources.allowsOptionalPreparation)
    XCTAssertEqual(promotedPaper?.sourceKey, sourceKey)
    XCTAssertEqual(promotedPaper?.page.artifact.pixelIdentity, artifact.pixelIdentity)
    XCTAssertEqual(promotedPaper?.image.width, 1024); XCTAssertEqual(promotedPaper?.image.height, 1408)
    XCTAssertEqual(resources.reservedBytes, baseline + 11 * mib, "Actual completed pixels retain their original grant under pressure")
    let opened = await source.pdf.openedDocumentCount()
    XCTAssertEqual(opened, 1)
    XCTAssertEqual(source.pdf.pendingOperationCount, 0)
    promotedPaper = nil
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertEqual(resources.reservedBytes, baseline)
  }


  func testMemoryPressureCancelsRequestedViewButKeepsDurableTargetUntilNormalResumes() async throws {
    let resources = SceneRenderResources.shared
    let previousPressure = resources.memoryPressureLevel
    resources.handleMemoryPressure(.normal)
    defer { resources.handleMemoryPressure(previousPressure) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-pressure-" + UUID().uuidString)
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    let size = PageSize(width: 320, height: 460)
    let header = try fixture.store.initializeWorkspace(actor: fixture.model.actorID, pageSize: size)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    let pageID = try XCTUnwrap(item.firstPageID)
    try fixture.store.savePresence(.init(boardID: header.rootBoardID, mode: .page,
      camera: .init(), viewport: .init(x: size.width, y: size.height),
      focusedItemID: item.id, openProgress: 1, selectedItemID: item.id, notebookPageID: pageID))
    let source = try fixture.store.readContentHeader(target: .init(kind: .page, id: pageID))
    let request = try fixture.store.requestPageVision(pageID: pageID,
      expectedRevision: XCTUnwrap(source.inkStamp).revision)
    let reading = NotebookPersistenceFenceContract.Blocker()
    let readCount = NotebookPersistenceFenceContract.Signal<Int>()
    let cancelledRead = NotebookPersistenceFenceContract.Signal<Bool>()
    let reader = NotebookSceneReader(store: fixture.store, beforeRead: {
      let count = (readCount.value ?? 0) + 1
      readCount.set(count)
      if count == 2 {
        try reading.hold()
        cancelledRead.set(Task.isCancelled)
        try Task.checkCancellation()
      }
    })
    let previousConfiguration = MacPreviewPublisher.acceptanceConfiguration
    MacPreviewPublisher.acceptanceConfiguration = .init(storeRoot: fixture.store.root,
      currentViewDelay: .zero, reconciliationInterval: .seconds(3_600), sourceReader: reader)
    let previousTargetHook = CurrentViewPreviewWriter.onPageVisionPrepared
    var targetContinuation: CheckedContinuation<Void, Never>?
    var targetCancelled: Bool?
    CurrentViewPreviewWriter.onPageVisionPrepared = { id in
      guard id == request.id else { return }
      await withCheckedContinuation { targetContinuation = $0 }
      targetCancelled = Task.isCancelled
    }
    defer {
      reading.release()
      let waiting = targetContinuation; targetContinuation = nil; waiting?.resume()
      MacPreviewPublisher.acceptanceConfiguration = previousConfiguration
      CurrentViewPreviewWriter.onPageVisionPrepared = previousTargetHook
    }
    var phase = "startup"
    func proof() -> [String: Any] {
      ["phase": phase, "automaticReadCount": readCount.value ?? 0,
        "automaticReadCancelled": cancelledRead.value.map { $0 as Any } ?? NSNull(),
        "durableTargetCancelled": targetCancelled.map { $0 as Any } ?? NSNull(),
        "durableRequestID": request.id.uuidString,
        "currentPreviewExists": FileManager.default.fileExists(atPath: fixture.store.currentViewPreviewURL.path),
        "pressure": String(describing: resources.memoryPressureLevel), "reconciliationSeconds": 3_600]
    }
    do {
      // Image demand enters the shared workspace service. The exact-root
      // configuration holds its second read after discovering the page source.
      try await fixture.start(pageSize: size)
      let imageRequest = Task { await fixture.model.prepareCurrentView() }
      defer { imageRequest.cancel() }
      phase = "requested-read-and-durable-target-held"
      try await waitUntil { reading.entered.value == true && targetContinuation != nil }
      XCTAssertNil(try fixture.store.loadCurrentViewReceipt())
      XCTAssertNil(try fixture.store.loadTargetRenderReceipt(request.id))
      resources.handleMemoryPressure(.warning)
      reading.release()
      phase = "pressure-cancelled-actual-read"
      try await waitUntil { cancelledRead.value != nil }
      XCTAssertEqual(cancelledRead.value, true, "Pressure cancels the actual automatic worker, not just its observer")
      XCTAssertNil(try fixture.store.loadCurrentViewReceipt())
      XCTAssertTrue(fixture.model.permitsBackgroundPreparation)
      XCTAssertFalse(fixture.model.permitsOptionalPreparation)
      XCTAssertEqual(try fixture.store.targetRenderRequests().map(\.id), [request.id])
      let waiting = targetContinuation; targetContinuation = nil; waiting?.resume()
      phase = "required-publications-under-pressure"
      try await waitUntil { (try? fixture.store.loadTargetRenderReceipt(request.id)) != nil }
      let targetReceipt = try XCTUnwrap(fixture.store.loadTargetRenderReceipt(request.id))
      XCTAssertEqual(targetCancelled, false, "An admitted durable target survives automatic preparation pressure")
      XCTAssertEqual(targetReceipt.request, request)
      XCTAssertEqual(targetReceipt.status, "ready", "\(targetReceipt.diagnostics)")
      let vision = try XCTUnwrap(fixture.store.loadPageVisionReceipt(pageID))
      XCTAssertEqual(vision.drawingStamp, try XCTUnwrap(source.inkStamp))
      let targetHash = try XCTUnwrap(targetReceipt.pngSHA256)
      XCTAssertEqual(targetHash, vision.previewPNG_SHA256)
      let artifact = try fixture.store.authorizedArtifact(.init(kind: .pageOverview, id: pageID,
        expectedSHA256: targetHash))
      XCTAssertEqual(artifact.path, fixture.store.previewURL(pageID).path)
      XCTAssertNotNil(NSImage(contentsOfFile: artifact.path))
      XCTAssertNil(try fixture.store.loadCurrentViewReceipt(), "The durable target does not revive optional current-view publication")
      await imageRequest.value
      phase = "next-request-after-pressure"
      resources.handleMemoryPressure(.normal)
      await fixture.model.prepareCurrentView()
      try await waitUntil { (try? fixture.store.loadCurrentViewReceipt()) != nil }
      let currentReceipt = try XCTUnwrap(fixture.store.loadCurrentViewReceipt())
      XCTAssertEqual(currentReceipt.presence.notebookPageID, pageID)
      XCTAssertNotNil(NSImage(contentsOf: fixture.store.currentViewPreviewURL))
      XCTAssertGreaterThan(readCount.value ?? 0, 2)
      XCTAssertEqual(try fixture.store.readContentHeader(target: .init(kind: .page, id: pageID)), source)
      phase = "completed"
      try attach(proof(), name: "preview-pressure-required-and-optional-owner")
    } catch {
      var failed = proof(); failed["error"] = String(describing: error)
      try? attach(failed, name: "preview-pressure-primary-failure-before-cleanup")
      throw error
    }
  }

  func testExtendedColorSnapshotFitsItsGrantBeforePublication() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let program = try BackgroundProgram(resources: resources)
    defer { program.close() }
    try await waitUntil { program.coordinator.ready }
    let size = program.coordinator.viewportSize
    let width = 256, height = Int(ceil(256 * size.height / size.width))
    let bytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: width, pixelHeight: height,
      bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel))
    let before = resources.reservedBytes
    var captureGrant: Int?
    program.coordinator.snapshotSubmission = { web, configuration, completion in
      captureGrant = resources.reservedBytes - before
      web.takeSnapshot(with: configuration, completionHandler: completion)
    }
    let lease = try await program.coordinator.capture(sourceOffset: 0, height: size.height, pixelWidth: width)
    defer { lease.release() }
    let bitmap = try XCTUnwrap(lease.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let grant = try XCTUnwrap(captureGrant, "The padded capture must own its complete grant before WebKit")
    XCTAssertGreaterThanOrEqual(grant, bytes)
    XCTAssertEqual(bitmap.width, width); XCTAssertEqual(bitmap.height, height)
    XCTAssertLessThanOrEqual(bitmap.bytesPerRow * bitmap.height * 2, grant)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, before + grant)
    XCTAssertEqual(resources.reservedBytes, before)

    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    let info = CGBitmapInfo.floatComponents.union(.byteOrder16Little).rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
      bytesPerRow: 0, space: space, bitmapInfo: info))
    context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1.5, 0.25, 0.5, 1])))
    context.fill(.init(x: 0, y: 0, width: width, height: height))
    let extended = try XCTUnwrap(context.makeImage())
    let normalized = try XCTUnwrap(NSImage.normalizedSnapshot(extended,
      region: .init(x: 0.25, y: 0.5, width: Double(width) - 0.5, height: Double(height) - 1),
      pixelSize: .init(width: width, height: height), logicalSize: size))
    let cropped = try XCTUnwrap(normalized.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(cropped.bitsPerComponent, extended.bitsPerComponent)
    XCTAssertEqual(cropped.bitsPerPixel, 64)
    XCTAssertEqual(cropped.bitmapInfo, extended.bitmapInfo)
    XCTAssertEqual(cropped.colorSpace?.name, extended.colorSpace?.name)
    XCTAssertLessThanOrEqual(cropped.bytesPerRow * cropped.height * 2, grant)
    let data = try XCTUnwrap(cropped.dataProvider?.data), samples = try XCTUnwrap(CFDataGetBytePtr(data))
    let center = (height / 2) * cropped.bytesPerRow + (width / 2) * 8
    let red = Float16(bitPattern: UInt16(samples[center]) | UInt16(samples[center + 1]) << 8)
    XCTAssertEqual(Float(red), 1.5, accuracy: 0.001, "The fractional cut must not clamp extended color to RGBA8")
  }

  func testActualNewDocumentPreparesItsOwnRequestedRasterWithoutASeededCache() async throws {
    try await check(contents: [.tex(id: "body", source: "\\section{A fresh source}\n\nIts real image must become available.")], name: "fresh-text")
  }

  func testPublicCollaborationCounterSourcePreparesItsOwnRaster() async throws {
    // The same authored counter lives in ordinary program files, not an old-format block decoder.
    try await check(contents: Self.publicContents, name: "public-collaboration-counter")
  }

  func testQueuedDocumentPreparationSurvivesRealBackgroundCapacityRelease() async throws {
    let resources = SceneRenderResources.shared
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = try (0..<resources.maximumBackgroundWebSurfaces).map { _ in try BackgroundProgram() }
    defer { blockers.forEach { $0.close() } }
    try await waitUntil { blockers.allSatisfy { $0.coordinator.ready } }
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, resources.maximumBackgroundWebSurfaces)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "body", html: "Waiting for physical capacity", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let started = ProcessInfo.processInfo.systemUptime
    var completedAt: Double?, releasedAt: Double?, failure: Error?, result: RasterLease?
    let preparation = Task { @MainActor in
      do { result = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0, programStore: blockers[0].store) }
      catch { failure = error }
      completedAt = ProcessInfo.processInfo.systemUptime
    }
    defer { preparation.cancel(); result?.release() }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let queuedAt = ProcessInfo.processInfo.systemUptime
    // The actual producer is intentionally unavailable longer than the old
    // reader's eight-second deadline. Capacity release, not a seeded cache or
    // readiness callback, permits the first real WebKit for this document.
    try await Task.sleep(for: .milliseconds(8_250))
    let completedBeforeCapacityRelease = completedAt != nil
    blockers.forEach { $0.close() }; releasedAt = ProcessInfo.processInfo.systemUptime
    await preparation.value
    let proof: [String: Any] = ["fixture": "actual-background-capacity", "physicalBlockers": blockers.count,
      "queuedAtMS": (queuedAt - started) * 1000,
      "capacityReleasedAtMS": (releasedAt! - started) * 1000,
      "completedAtMS": (completedAt! - started) * 1000,
      "completedBeforeCapacityRelease": completedBeforeCapacityRelease,
      "error": failure.map { String(describing: $0) } ?? "none", "returned": result != nil,
      "pendingAfterCompletion": resources.pendingWebRequestCount]
    try attach(proof, name: "actual-background-capacity-result")
    XCTAssertFalse(completedBeforeCapacityRelease, "A queued source has not failed to render before it owns any WebKit")
    XCTAssertNil(failure)
    XCTAssertNotNil(result, "The same accepted preparation must finish after its admission is released")
  }

  func testCancellationRetiresQueuedPreparationWithoutAWebKitOrLateImage() async throws {
    let resources = SceneRenderResources.shared
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = try (0..<resources.maximumBackgroundWebSurfaces).map { _ in try BackgroundProgram() }
    defer { blockers.forEach { $0.close() } }
    try await waitUntil { blockers.allSatisfy { $0.coordinator.ready } }
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "body", html: "Never admitted", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let preparation = Task { try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0, programStore: blockers[0].store) }
    defer { preparation.cancel() }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    preparation.cancel()
    do { let unexpected = try await preparation.value; unexpected.release(); XCTFail("Cancelled request returned pixels") }
    catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }
    try await waitUntil { resources.pendingWebRequestCount == 0 }
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, blockers.count)
    blockers.forEach { $0.close() }
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 }
    XCTAssertNil(resources.retainRaster(for: source))
    try attach(["fixture": "cancelled-background-request", "pending": resources.pendingWebRequestCount,
      "activeBackground": resources.activeBackgroundWebSurfaceCount,
      "lateImage": resources.image(for: source) != nil], name: "cancelled-background-request-result")
  }

  func testAccessoryWithoutAnOwnVisibleWindowPreparesThePublicCounter() async throws {
    let application = NSApplication.shared
    let policy = application.activationPolicy()
    let visible = application.windows.filter(\.isVisible)
    _ = application.setActivationPolicy(.accessory)
    XCTAssertEqual(application.activationPolicy(), .accessory)
    visible.forEach { $0.orderOut(nil) }
    defer {
      _ = application.setActivationPolicy(policy)
      visible.forEach { $0.orderBack(nil) }
    }
    XCTAssertTrue(application.windows.allSatisfy { !$0.isVisible })
    try await check(contents: Self.publicContents, name: "accessory-no-own-visible-window")
  }

  func testCapturePressureKeepsThePreparedSourceUntilItsWholeRasterFits() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = nativePaper(resources: resources); defer { paper.close() }
    try await paper.prepare()
    let source = paper.source, measurements = source.measurementCount
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - resources.reservedBytes - 1_000_000, priority: .passive))
    let small = try XCTUnwrap(resources.reserveDerivedBytes(100_000, priority: .passive))
    defer { held.release(); small.release() }
    let capture = Task { try await paper.retainPreparedSnapshot(pixelWidth: 512, waitsForRasterAdmission: true) }
    defer { capture.cancel() }
    try await waitUntil { paper.isWaitingForRasterAdmission }
    small.release(); try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(paper.isWaitingForRasterAdmission)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    held.release()
    let raster = try await capture.value; defer { raster.release() }
    XCTAssertFalse(paper.isWaitingForRasterAdmission)
    XCTAssertTrue(paper.source === source); XCTAssertEqual(source.measurementCount, measurements)
  }

  func testStoppingAProducerCancelsItsPendingCaptureBeforeCapacityReturns() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = nativePaper(resources: resources); defer { paper.close() }
    try await paper.prepare()
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - resources.reservedBytes - 1_000_000, priority: .passive))
    defer { held.release() }
    let capture = Task { try await paper.retainPreparedSnapshot(pixelWidth: 512, waitsForRasterAdmission: true) }
    try await waitUntil { paper.isWaitingForRasterAdmission }
    paper.close()
    do { let unexpected = try await capture.value; unexpected.release(); XCTFail("Retired image request published pixels") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    held.release()
    XCTAssertFalse(paper.isWaitingForRasterAdmission)
    XCTAssertEqual(resources.rasterCount, 0)
  }

  func testImpossibleCaptureDoesNotCreateAPermanentAdmissionWaiter() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = nativePaper(resources: resources); defer { paper.close() }
    try await paper.prepare()
    do {
      let unexpected = try await paper.retainPreparedSnapshot(pixelWidth: 8192, waitsForRasterAdmission: true)
      unexpected.release(); XCTFail("An impossible capture exceeded its fixed budget")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertFalse(paper.isWaitingForRasterAdmission); XCTAssertEqual(resources.rasterCount, 0)
  }

  private func nativePaper(resources: SceneRenderResources) -> DocumentPageRaster {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "A native prepared paper")])
    return DocumentPageRaster(document: document, state: .init(id: document.id, actor: UUID()), pageIndex: 0,
      resources: resources, programStore: nil, isolationID: nil, renderSession: nil, purpose: { .required })
  }

  func testActualBrokenImageReturnsItsRenderFailureRatherThanReaderCancellation() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("broken-document-image-" + UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let bytes = Data("not-an-image".utf8), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try store.stageBlob(data: bytes, expectedHash: hash)
    let document = DocumentDocument(actor: UUID(), files: [
      .init(id: "main", path: "main.tex", source: "\\documentclass{article}\\usepackage{graphicx}\\begin{document}\\includegraphics{images/broken.png}\\end{document}"),
      .init(id: "image", path: "images/broken.png", resource: .init(path: "images/broken.png", mimeType: "image/png",
        byteCount: Int64(bytes.count), parts: [.init(sha256: hash, byteCount: bytes.count)]))])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    do {
      let unexpected = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
        pageIndex: 0, resources: resources, programStore: store)
      unexpected.release(); XCTFail("An undecodable physical image was reported as a prepared page")
    } catch {
      XCTAssertFalse(error is CancellationError, "Internal reader retirement must retain the actual renderer failure")
      XCTAssertTrue(error.localizedDescription.contains("broken.png"), "\(error)")
      try attach(["actualBrokenImageError": String(describing: error)], name: "actual-broken-image-render-error")
    }
    try await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == 0 }
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.rasterCount, 0)
  }

  func testQueuedTargetRequestHasNoTerminalReceiptAndPublishesAfterCapacityReturns() async throws {
    let resources = SceneRenderResources.shared
    var phase = "await_empty_background_pool"
    var events: [[String: Any]] = []
    let started = ProcessInfo.processInfo.systemUptime
    func mark(_ next: String) {
      phase = next
      events.append(["phase": next, "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
    }
    defer { try? attach(["events": events, "lastPhase": phase], name: "queued-target-owner-boundaries") }
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = try (0..<resources.maximumBackgroundWebSurfaces).map { _ in try BackgroundProgram() }
    defer { blockers.forEach { $0.close() } }
    do {
      mark("await_actual_blocker_pixels")
      try await waitUntil { blockers.allSatisfy { $0.coordinator.ready } }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = NotebookStore(root: directory), actor = UUID()
      mark("create_store")
      var (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
      mark("load_board")
      var board = try store.loadBoard(items: workspace.items)
      mark("create_document")
      let item = try XCTUnwrap(workspace.createDocument(title: "Queued target", actor: actor))
      let document = DocumentTestFiles.document(id: item.id, actor: actor, contents: [.program(id: "body", html: "A real queued target", height: 100)])
      XCTAssertTrue(board.addItem(item.id, to: workspace.rootBoardID, near: .zero, actor: actor))
      mark("publish_document_bundle")
      try store.saveDocumentWorkspaceBundle(index: workspace, document: document,
        state: .init(id: document.id, actor: actor), board: board)
      mark("prepare_spatial_ink")
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      let target = CollaborationTarget(kind: .document, id: document.id)
      let revision = document.contentStamp.revision
      mark("accept_target_request")
      let request = try store.requestTargetRender(target: target, expectedRevision: revision)
      mark("create_preview_owner")
      let model = NotebookAppModel(store: store, startsNearbySync: false)
      let publisher = MacPreviewPublisher(model: model)
      addTeardownBlock { @MainActor in
        await publisher.stop()
        let stopped = await model.shutdown(); XCTAssertTrue(stopped)
        if stopped { try FileManager.default.removeItem(at: directory) }
      }
      mark("start_preview_owner")
      publisher.start()
      mark("await_request_in_real_queue")
      try await waitUntil { resources.pendingWebRequestCount == 1 }
      mark("hold_capacity_past_previous_deadline")
      try await Task.sleep(for: .milliseconds(8_250))
      mark("verify_pending_has_no_terminal_receipt")
      XCTAssertNil(try store.loadTargetRenderReceipt(request.id), "Waiting for admission is not an immutable rendering error")
      let repeated = try store.requestTargetRender(target: target, expectedRevision: revision)
      XCTAssertEqual(repeated, request, "A retry reads the accepted request; it does not manufacture another identity")
      mark("release_background_capacity")
      blockers.forEach { $0.close() }
      mark("await_actual_terminal_receipt")
      try await waitUntil { (try? store.loadTargetRenderReceipt(request.id)) != nil }
      let receipt = try XCTUnwrap(store.loadTargetRenderReceipt(request.id))
      XCTAssertEqual(receipt.status, "ready", "\(receipt.diagnostics)")
      XCTAssertEqual(receipt.request, request)
      XCTAssertNotNil(NSImage(contentsOf: store.targetPNGURL(request.id)))
      mark("stop_preview_owner")
      await publisher.stop()
      mark("completed")
    } catch {
      let actual = error as NSError
      try? attach(["phase": phase, "error": String(describing: error),
        "errorType": String(reflecting: type(of: error)), "domain": actual.domain, "code": actual.code,
        "events": events], name: "queued-target-primary-error-before-cleanup")
      XCTFail("Queued target failed at \(phase): \(error)")
      throw error
    }
  }

  @MainActor private final class BackgroundProgram {
    let coordinator: DocumentBlockRuntime
    let store: NotebookStore
    private var window: NSWindow?
    init(resources: SceneRenderResources = .shared) throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("background-program-" + UUID().uuidString))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      let document = DocumentTestFiles.document(contents: [.program(id: "blocker", html: "<p>A retained browser</p>", height: 100)])
      let program = try store.documentProgramSource(document: document, instanceID: "blocker", path: "programs/blocker")
      coordinator = DocumentBlockRuntime(documentID: document.id, program: program, value: program.initialState,
        stateVersion: nil, width: 600, height: 100, resources: resources, programStore: store)
      coordinator.requiresStateAcceptance = false
      coordinator.onMount = { [weak self] web, size in
        let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil); self?.window = window
      }
      coordinator.start(priority: .background)
    }
    func close() { coordinator.stop(); window?.orderOut(nil); window?.close(); window = nil }
    isolated deinit { close(); try? FileManager.default.removeItem(at: store.root) }
  }

  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Actual owner state did not arrive", file: file, line: line)
    if !condition() { throw NSError(domain: "DocumentTargetPreparationTests", code: 1) }
  }

  private func attach(_ value: [String: Any], name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    proof.name = name; proof.lifetime = .keepAlways; add(proof)
  }

  private func check(contents: [DocumentTestFiles], name: String) async throws {
    let actor = UUID(), document = DocumentTestFiles.document(actor: UUID(), contents: contents)
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("document-preview-" + UUID().uuidString))
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    XCTAssertNil(SceneRenderResources.shared.retainRaster(for: source))
    let screenScaleBeforePreparation = NSScreen.main?.backingScaleFactor
    let keyWindowBeforePreparation = NSApplication.shared.keyWindow != nil
    let visibleWindowsBeforePreparation = NSApplication.shared.windows.filter(\.isVisible).count
    let policyBeforePreparation = NSApplication.shared.activationPolicy().rawValue
    let started = ProcessInfo.processInfo.systemUptime
    var failure: Error?, result: RasterLease?
    do { result = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0, programStore: store) }
    catch { failure = error }
    defer { result?.release() }
    let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    // The probe runs only after the real call. It must not manufacture an own
    // window before NSScreen.main is sampled by the production owner.
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    let probe = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    probe.isReleasedWhenClosed = false; probe.orderBack(nil)
    let probeScale = probe.backingScaleFactor
    probe.orderOut(nil); probe.close()
    let cached = SceneRenderResources.shared.retainRaster(for: source)
    defer { cached?.release() }
    let cachedPixels = cached?.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    let evidence: [String: Any] = ["fixture": name, "documentID": document.id.uuidString,
      "elapsedMS": elapsedMS,
      "screenScaleBeforePreparation": screenScaleBeforePreparation.map { $0 as Any } ?? NSNull(),
      "hadKeyWindowBeforePreparation": keyWindowBeforePreparation,
      "visibleOwnWindowsBeforePreparation": visibleWindowsBeforePreparation,
      "activationPolicyBeforePreparation": policyBeforePreparation,
      "screenRequiredScale": Double(NSScreen.main?.backingScaleFactor ?? 2),
      "sameGeometryProbeWindowScale": probeScale, "returned": result != nil,
      "actualCacheScale": cached?.pixelScale ?? 0, "actualCachePresent": cached != nil,
      "actualCachePixelWidth": cachedPixels?.width ?? 0, "actualCachePixelHeight": cachedPixels?.height ?? 0,
      "sourceToken": DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0),
      "error": failure.map { String(describing: $0) } ?? "none",
      "activeWebSurfacesAfterReturn": SceneRenderResources.shared.activeWebSurfaceCount]
    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
    let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    proof.name = name + "-actual-preview-result"; proof.lifetime = .keepAlways; add(proof)
    if let result {
      let image = XCTAttachment(image: result.image)
      image.name = name + "-actual-preview-image"; image.lifetime = .keepAlways; add(image)
    }
    XCTAssertNil(failure, String(decoding: data, as: UTF8.self))
    XCTAssertNotNil(result, "The live preparation path must return its own actual raster")
    if let result {
      XCTAssertGreaterThanOrEqual(result.pixelScale + 0.000_001, Double(NSScreen.main?.backingScaleFactor ?? 2),
        "The exact requested raster must retain its admitted display density")
    }
  }

  private static var publicContents: [DocumentTestFiles] { [
    .tex(id: "collaboration-explanation", source: "Сохранённое состояние и независимый счётчик. Кнопка прибавляет один; значение остаётся доступным после повторного открытия."),
    .program(id: "collaboration-counter-2c047f99-97ed-4108-a072-19d4b28b1427", html: "<main><button type=\"button\" id=\"increment\" aria-label=\"Collaboration increment 2c047f99-97ed-4108-a072-19d4b28b1427\">Прибавить один</button><output id=\"count\" aria-live=\"polite\">Collaboration count 2c047f99-97ed-4108-a072-19d4b28b1427: 0</output></main>", css: "*{box-sizing:border-box}html,body{margin:0;background:#fff;color:#172733;font:18px -apple-system,sans-serif}main{display:grid;gap:18px;padding:12px}button{font:inherit;min-height:52px;padding:12px 18px;background:#1675a9;color:white;border:0;border-radius:12px;cursor:pointer}button:focus-visible{outline:3px solid #172733;outline-offset:3px}output{display:block;overflow-wrap:anywhere;line-height:1.45;font-variant-numeric:tabular-nums}",
      javaScript: "const button=document.getElementById(\"increment\");\nconst output=document.getElementById(\"count\");\nconst count=()=>notebook.state?.count ?? 0;\nconst draw=()=>{output.textContent=\"Collaboration count 2c047f99-97ed-4108-a072-19d4b28b1427: \"+count();};\nbutton.addEventListener(\"click\",()=>{notebook.commit({count:count()+1});draw();});\naddEventListener(\"notebookstate\",draw);\nnotebook.ready(Promise.resolve().then(draw));", initialState: .object(["count": .number(0)]), height: 180)
  ] }
}

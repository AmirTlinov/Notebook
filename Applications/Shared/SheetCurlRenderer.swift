import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Opening a cover reserves travel outside the physical sheet; turning an
/// interior page stays clipped to its viewport. Neither changes hit geometry.
struct SheetCurlLayout: Equatable {
  static let openingTravelRatio = 1.0
  static let shadowMarginRatio = 0.04

  let sheetSize: CGSize
  let shadowMargin: CGFloat
  let clipsToSheet: Bool

  init(sheetSize: CGSize, clipsToSheet: Bool = false) {
    precondition(sheetSize.width > 0 && sheetSize.height > 0)
    self.sheetSize = sheetSize
    self.clipsToSheet = clipsToSheet
    shadowMargin = clipsToSheet ? 0 : min(sheetSize.width, sheetSize.height) * Self.shadowMarginRatio
  }

  var sheetFrame: CGRect {
    CGRect(
      x: (clipsToSheet ? 0 : sheetSize.width * Self.openingTravelRatio) + shadowMargin,
      y: shadowMargin,
      width: sheetSize.width,
      height: sheetSize.height
    )
  }

  var canvasSize: CGSize {
    CGSize(
      width: sheetFrame.maxX + shadowMargin,
      height: sheetFrame.maxY + shadowMargin
    )
  }

  /// The Metal canvas is a child of the sheet-sized platform view. Its origin
  /// is shifted so the sheet inside the canvas remains exactly at `(0, 0)`.
  var canvasFrameAroundSheet: CGRect {
    CGRect(
      x: -sheetFrame.minX,
      y: -sheetFrame.minY,
      width: canvasSize.width,
      height: canvasSize.height
    )
  }

  func sheetExtent(inDrawableSize drawableSize: CGSize) -> CGRect {
    let scaleX = drawableSize.width / canvasSize.width
    let scaleY = drawableSize.height / canvasSize.height
    return CGRect(
      x: sheetFrame.minX * scaleX,
      y: sheetFrame.minY * scaleY,
      width: sheetFrame.width * scaleX,
      height: sheetFrame.height * scaleY
    )
  }
}

/// One device/queue and prebuilt interior-page pipeline. Covers retain their
/// separate Core Image geometry, compiled once outside the interactive frame;
/// individual views own their drawables and finite in-flight limit.
final class SheetCurlGPU: @unchecked Sendable {
  static let shared = SheetCurlGPU()

  let device: (any MTLDevice)?
  let commandQueue: (any MTLCommandQueue)?
  private let coverLock = NSLock()
  private var contextResult: Result<CIContext, SceneRenderError>?
  private var contextReaders: [UUID: CheckedContinuation<CIContext, any Error>] = [:]
  private var coverResult: Result<CIContext, SceneRenderError>?
  private var coverObservers: [UUID: @MainActor @Sendable (Result<CIContext, SceneRenderError>) -> Void] = [:]
  let pagePipeline: (any MTLRenderPipelineState)?

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    if let device, let library = try? device.makeDefaultLibrary(bundle: .main) {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "pageCurlVertex")
      descriptor.fragmentFunction = library.makeFunction(name: "pageCurlFragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      pagePipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    } else { pagePipeline = nil }
    commandQueue = device?.makeCommandQueue()
    // Start once with this GPU owner, before a cover gesture. Page captures
    // borrow the context asynchronously; mounting never constructs Core Image.
    let queue = commandQueue
    Task.detached(priority: .userInitiated) { [self] in
      let result: Result<CIContext, SceneRenderError>
      do {
        guard let device, let queue else { throw SceneRenderError.snapshotPending("image_context_device") }
        let context = CIContext(mtlDevice: device,
          options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
        publishContext(.success(context))
        try await Self.prepareCoverContext(context, queue: queue)
        result = .success(context)
      } catch {
        let failure = (error as? SceneRenderError) ?? .snapshotPending("cover_program")
        // A cover-only warmup failure cannot revoke a usable compositor.
        publishContext(.failure(failure))
        result = .failure(failure)
      }
      let observers = coverLock.withLock {
        coverResult = result
        let values = Array(coverObservers.values); coverObservers.removeAll()
        return values
      }
      await MainActor.run { for observer in observers { observer(result) } }
    }
  }

  /// A page borrows the common context as soon as it exists; cover program
  /// compilation and its GPU warmup are a separate readiness boundary.
  func imageContext() async throws -> CIContext {
    let id = UUID()
    let context: CIContext = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CIContext, any Error>) in
        let ready: Result<CIContext, any Error>? = coverLock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if let contextResult { return contextResult.mapError { $0 as any Error } }
          contextReaders[id] = continuation
          return nil
        }
        if let ready { continuation.resume(with: ready) }
      }
    } onCancel: {
      let reader = self.coverLock.withLock { self.contextReaders.removeValue(forKey: id) }
      reader?.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
    return context
  }

  private func publishContext(_ result: Result<CIContext, SceneRenderError>) {
    let readers: [CheckedContinuation<CIContext, any Error>] = coverLock.withLock {
      guard contextResult == nil else { return [] }
      contextResult = result
      let values = Array(contextReaders.values); contextReaders.removeAll()
      return values
    }
    for reader in readers { reader.resume(with: result.mapError { $0 as any Error }) }
  }

  var preparedCoverContext: Result<CIContext, SceneRenderError>? { coverLock.withLock { coverResult } }

  @MainActor func observeCover(_ id: UUID,
    _ completion: @escaping @MainActor @Sendable (Result<CIContext, SceneRenderError>) -> Void) {
    let ready: Result<CIContext, SceneRenderError>? = coverLock.withLock {
      if let coverResult { return coverResult }
      coverObservers[id] = completion
      return nil
    }
    if let ready { Task { @MainActor in completion(ready) } }
  }

  func removeCoverObserver(_ id: UUID) { _ = coverLock.withLock { coverObservers.removeValue(forKey: id) } }

  private static func prepareCoverContext(_ context: CIContext, queue: any MTLCommandQueue) async throws {
    guard let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
      bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(extent)
    guard let pixels = bitmap.makeImage() else { throw SceneRenderError.resourceLimit }
    // Compile the path actually used by a turn: bitmap upload and BGRA Metal
    // output. A constant-colour graph rendered to CGImage omits those kernels
    // and leaves their compilation on the first input event.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
      width: 64, height: 64, mipmapped: false)
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    guard let texture = queue.device.makeTexture(descriptor: descriptor),
      let command = queue.makeCommandBuffer(),
      let output = curlImage(input: CIImage(cgImage: pixels),
        backside: CIImage(color: CoverBacksideColor.document.ciColor).cropped(to: extent),
        sheetExtent: extent, canvasExtent: extent, progress: 0.1, radius: 2.24) else { throw SceneRenderError.snapshotPending("cover_program") }
    context.render(output, to: texture, commandBuffer: command, bounds: extent,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    // The suspended producer owns these resources until the GPU completion;
    // the Metal callback only transfers the outcome, not mutable GPU objects.
    defer { withExtendedLifetime((context, texture)) {} }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      command.addCompletedHandler { completed in
        if completed.status == .completed { continuation.resume() }
        else { continuation.resume(throwing: SceneRenderError.snapshotPending("cover_program_gpu")) }
      }
      command.commit()
    }
  }

  static func curlImage(input: CIImage, backside: CIImage, sheetExtent: CGRect,
    canvasExtent: CGRect, progress: Double, radius: Float) -> CIImage? {
    let filter = CIFilter.pageCurlWithShadowTransition()
    filter.inputImage = input
    filter.targetImage = CIImage(color: .clear).cropped(to: sheetExtent)
    filter.backsideImage = backside
    filter.extent = sheetExtent
    filter.time = Float(progress)
    filter.angle = .pi
    filter.radius = radius
    filter.shadowSize = CoverOpeningPhysics.systemShadowSize
    filter.shadowAmount = CoverOpeningPhysics.systemShadowAmount
    filter.shadowExtent = canvasExtent
    return filter.outputImage?.cropped(to: canvasExtent)
  }
}

/// Metal records scheduling directly; the page's CA phase consumes this receipt
/// without a worker-to-main task. Covers use it only for optional measurement.
private final class SheetCurlScheduleTiming: @unchecked Sendable {
  private let lock = NSLock()
  private let scheduled = DispatchSemaphore(value: 0)
  private var timestamp: TimeInterval?
  func record() {
    lock.withLock { timestamp = CACurrentMediaTime() }
    scheduled.signal()
  }
  var value: TimeInterval? { lock.withLock { timestamp } }

  /// This is a scheduling fence, not a GPU-completion wait. UIKit's normal
  /// phases run consecutively: polling once just after encoding would always
  /// miss the same update. A late command may consume at most 1 ms, while
  /// leaving at least 0.5 ms of the actual update deadline for CA publication.
  func waitForScheduling(completionDeadline: TimeInterval) -> Bool {
    if value != nil { return true }
    let remaining = min(0.001, completionDeadline - CACurrentMediaTime() - 0.0005)
    guard remaining > 0 else { return false }
    _ = scheduled.wait(timeout: .now() + remaining)
    return value != nil
  }
}

#if os(iOS)
/// One outstanding pool request, never a main-thread nextDrawable wait. The
/// request retains admission until even a cancelled late drawable is drained.
private final class SheetCurlDrawableRequest: @unchecked Sendable {
  private let lock = NSLock()
  private let layer: CAMetalLayer
  private let reservation: RasterReservation?
  private var cancelled = false
  private var completed = false
  private var drained = false
  private var drawable: (any CAMetalDrawable)?
  private var drainCallbacks: [@MainActor @Sendable () -> Void] = []

  init(layer: CAMetalLayer, reservation: RasterReservation?) {
    self.layer = layer; self.reservation = reservation
  }
  func start(completed callback: @escaping @MainActor @Sendable () -> Void) {
    Task.detached(priority: .userInitiated) { [self] in
      autoreleasepool {
        let value = layer.nextDrawable()
        lock.withLock {
          completed = true
          if !cancelled { drawable = value }
        }
        withExtendedLifetime(reservation) {}
      }
      let callbacks = lock.withLock {
        drained = true
        let callbacks = drainCallbacks; drainCallbacks.removeAll()
        return callbacks
      }
      await MainActor.run { callbacks.forEach { $0() }; callback() }
    }
  }

  var hasFailed: Bool { lock.withLock { completed && !cancelled && drawable == nil } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  func take() -> (any CAMetalDrawable)? {
    lock.withLock {
      guard drained, !cancelled else { return nil }
      let value = drawable; drawable = nil
      return value
    }
  }
  @discardableResult
  func cancel() -> Bool {
    lock.withLock { cancelled = true; drawable = nil; return drained }
  }
  @MainActor func holds(_ value: RasterReservation) -> Bool { reservation === value }
  @MainActor func whenDrained(_ callback: @escaping @MainActor @Sendable () -> Void) {
    let alreadyDrained = lock.withLock {
      if drained { return true }
      drainCallbacks.append(callback); return false
    }
    if alreadyDrained { callback() }
  }
}

/// The native page renderer owns one exact-size pool, including idle IOSurfaces.
/// Only a drained, hidden pool can be offered to the existing resource planner.
@MainActor
private final class SheetCurlPageOutput {
  let id: UUID
  let layer: CAMetalLayer
  let size: CGSize
  let reservation: RasterReservation
  private let physical: ScenePhysicalOwnerLease
  private var released = false
  var isIdle = false

  init(device: any MTLDevice, size: CGSize, bytes: Int, count: Int) throws {
    let resources = SceneRenderResources.shared
    let id = UUID(); self.id = id
    let physical = resources.reservePhysicalOwners([.pageCurl(id)], priority: .input)
    guard let reservation = resources.reserveDerivedBytes(bytes, priority: .input, owner: physical) else {
      physical.release(); throw SceneRenderError.resourceLimit
    }
    self.physical = physical; self.reservation = reservation; self.size = size
    let output = CAMetalLayer()
    output.device = device; output.pixelFormat = .bgra8Unorm
    output.framebufferOnly = true; output.isOpaque = true
    output.maximumDrawableCount = count; output.drawableSize = size
    output.isHidden = true
    layer = output
  }

  func activate() {
    isIdle = false
    SceneRenderResources.shared.updatePhysicalPriorities([.pageCurl(id): .input], reclassifyingExistingBacking: true)
  }
  func idle() {
    guard !released else { return }
    isIdle = true
    SceneRenderResources.shared.updatePhysicalPriorities([.pageCurl(id): .passive], reclassifyingExistingBacking: true)
    SceneRenderResources.shared.reclamationOffersChanged()
  }
  func release() {
    guard !released else { return }
    released = true; isIdle = false
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.isHidden = true; layer.removeFromSuperlayer()
    CATransaction.commit()
    reservation.release(); physical.release()
  }
  isolated deinit { release() }
}

/// A terminal joins the physical pool request and ordered GPU fence. Completion
/// releases admission explicitly, independent of Metal's callback retention.
@MainActor
private final class SheetCurlPageRetirement {
  private var completion: (() -> Void)?
  private var gpuDrained = false
  private var drawableDrained = false
  init(_ completion: @escaping () -> Void) { self.completion = completion }
  func finishGPU() { gpuDrained = true; finish() }
  func finishDrawable() { drawableDrained = true; finish() }
  private func finish() {
    guard gpuDrained, drawableDrained, let completion else { return }
    self.completion = nil
    completion()
  }
}
#endif

/// One presentation owner: covers use their outside-sheet Core Image geometry;
/// interior pages render a complete frozen pair with the analytic Metal kernel.
@MainActor
final class SheetCurlMetalView: MTKView, MTKViewDelegate {
  struct FrameTiming: Sendable {
    let operationID: UUID?
    let sequence: Int
    let clockRequested, displayUpdateReceived: TimeInterval?
    let encodingBegan, submitted, gpuBegan, gpuEnded, renderingDeadline, targetPresentation: TimeInterval
    let scheduled: TimeInterval?
  }
  var permitsFrameSubmission: @MainActor () -> Bool = { false }
  private(set) var submittedFrameCount = 0
  var drawableCount: Int {
    #if os(iOS)
    // A displayed page and its CA-queued successor still need a render target.
    // Cover rendering retains its existing two-drawable allocation.
    return onDisplayUpdate == nil ? 2 : 3
    #else
    return 2
    #endif
  }
  var frameLease: RasterReservation?
  /// Display-only instrumentation; Simulator never sends this callback.
  var onFramePresented: ((CGImage, Double, TimeInterval) -> Void)?
  var onFrameReady: ((CGImage, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  #if os(iOS)
  struct PageUpdateTiming: Sendable {
    enum Phase: String, Sendable { case prepared, exposed, beforePresent, afterPresent, beforeCommit, afterCommit }
    let operationID: UUID
    let generation: UInt64
    let phase: Phase
    let nextSequence: Int
    let recorded: TimeInterval
    let modelTime, completionDeadline, estimatedPresentation: TimeInterval?
    let viewHidden, layerHidden, windowAttached: Bool
    let layerOpacity: Float
    let presentsWithTransaction: Bool
    let drawableMatchesLayer: Bool?
    let immediatePresentationExpected: Bool?
  }
  /// Opt-in observation of the layer-tree boundary, separate from the Metal/OS
  /// receipt: first six CA phases and three present calls only.
  var onPageUpdateMeasured: ((PageUpdateTiming) -> Void)?
  var onPageFrameReady: ((PageTurnFrame, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  var onPageFrameWillPresent: ((UUID) -> Void)?
  var onPageRenderFailure: ((Error) -> Void)?
  var onPageDetached: (() -> Void)?
  var onCoverFrameReady: ((PageTurnFrame, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  private var sourceCoverFrame: PageTurnFrame?
  private var pageFrames: (leaf: PageTurnFrame, base: PageTurnFrame)?
  private var pageOperationID: UUID?
  private var pageClockRequestedAt: TimeInterval?
  private var pagePresentationGeneration: UInt64 = 0
  private var pageUpdateMeasurement: (generation: UInt64, remainingPhases: Int)?
  private var pageMeasuredPublications = 0
  /// Pages own their drawable pool directly. The inherited MTK backing and its
  /// display/resize lifecycle belong exclusively to cover rendering.
  private var pageOutput: SheetCurlPageOutput?
  var pageOutputLayer: CAMetalLayer? { pageOutput?.layer }
  var pageDrawableReservedBytes: Int { pageOutput?.reservation.byteCount ?? 0 }
  private var pageReclamationOwner: UUID?
  private var pageHasPublishedFrame = false
  private enum PagePresentationPhase {
    case initial
    case awaitingOS(sequence: Int, drawable: any CAMetalDrawable)
    case motion
  }
  private var pagePresentationPhase = PagePresentationPhase.initial
  private var pageAnimationTime: TimeInterval?
  struct PagePose: Sendable {
    let progress, anchor, tilt: Double
  }
  private var pagePose: PagePose?
  private(set) var presentedPagePose: PagePose?
  private var pagePresentedSequence = -1
  private var pagePresentedTime: TimeInterval?
  private var pageDrawableRequest: SheetCurlDrawableRequest?
  private struct PagePublication {
    let operationID: UUID
    let generation: UInt64
    let drawable: any CAMetalDrawable
    let command: any MTLCommandBuffer
    let schedule: SheetCurlScheduleTiming
    let poseRevision: UInt64
    let sequence: Int
  }
  private var pagePublication: PagePublication?
  private var pagePoseRevision: UInt64 = 0
  private var configuringPageDrawable = false
  private var pendingPageDrawableSize: CGSize?
  #endif
  /// Source reveal and the flat-sheet boundary share their drawable's CA
  /// transaction. The native owner installs the paper beneath that exact frame.
  var onWillPresentFrame: ((CGImage, Double) -> Void)?
  // An opt-in, bounded diagnostic at the actual submission owner. It does not
  // alter admission, clock, command ordering or the presentation receipt.
  var onFrameMeasured: ((FrameTiming) -> Void)?
  /// Page motion and its drawable share UIKit's update and CA publication.
  /// Covers are event-driven and do not install a second animation clock.
  var onDisplayUpdate: ((TimeInterval) -> Void)?
  var animatesContinuously = false {
    didSet { if animatesContinuously { requestFrame() } }
  }
  #if os(iOS)
    private var pageUIUpdates: UIUpdateLink?
  #endif

  func releaseSource(presented: Bool = false) {
    cancelCoverContextSubscription()
    coverContextRequested = false
    #if os(iOS)
    let releasesPage = onDisplayUpdate != nil || pageOperationID != nil || pageDrawableRequest != nil
    let retiringRequest = pageDrawableRequest
    let retiringOutput = pageOutput
    // Visibility is revoked now, independently of asynchronous GPU/pool drain.
    // A successor can reveal its parent before the old fence callback runs.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    retiringOutput?.layer.isHidden = true
    CATransaction.commit()
    // Only an actual endpoint permits pool reuse. An interrupted asynchronous
    // presentation can still be queued in CA; its layer must never reappear.
    if !presented { pageOutput = nil }
    retirePageExecution()
    pendingPageDrawableSize = nil
    #endif
    animatesContinuously = false
    sourceCover = nil; coverImage = nil; pageTextures = nil; framePending = false
    #if os(iOS)
    pagePresentationGeneration &+= 1
    pageFrames = nil; sourceCoverFrame = nil; pageOperationID = nil; pageClockRequestedAt = nil
    pagePose = nil; presentedPagePose = nil; pagePresentedSequence = -1; pagePresentedTime = nil
    pageUpdateMeasurement = nil
    pageMeasuredPublications = 0
    #endif
    let lease = frameLease
    frameLease = nil
    #if os(iOS)
    pageUIUpdates?.isEnabled = false
    #endif
    #if os(iOS)
    if releasesPage {
      guard let retiringOutput else { return }
      let generation = pagePresentationGeneration
      drainPageOutput(retiringOutput, request: retiringRequest) { [weak self] in
        if presented {
          // Replacement/detach owns its later fence. This older terminal
          // must not release backing used by commands from a newer operation.
          guard let self, self.pageOutput === retiringOutput else { return }
          // A newer accepted operation may already have promoted this pool.
          if self.pageOperationID == nil, self.pagePresentationGeneration == generation { retiringOutput.idle() }
        } else { retiringOutput.release() }
      }
      return
    }
    #endif
    releaseDrawables()
    guard let lease else { return }
    if presented { lease.release(); return }
    // Completion handlers can remain retained by a command buffer. Their
    // Swift lifetime is not a release receipt. Drain the ordered GPU queue
    // explicitly before returning this turn's finite backing to admission.
    guard let fence = commandQueue?.makeCommandBuffer() else { lease.release(); return }
    fence.addCompletedHandler { _ in Task { @MainActor in lease.release() } }
    fence.commit()
  }

  private var framePending = false
  private let commandQueue: (any MTLCommandQueue)?
  private var imageContext: CIContext?
  private var coverContextSubscription: UUID?
  private var coverContextRequested = false
  private var coverContextFailure: SceneRenderError?
  var onCoverRenderingReady: (() -> Void)?
  var onCoverRenderFailure: ((Error) -> Void)?
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private let inFlightSemaphore = DispatchSemaphore(value: 2)

  private var coverImage: CIImage?
  private var progress = 0.0
  private var backsideColor = CoverBacksideColor.document
  private var cornerRadius: CGFloat = 0
  private var curlLayout: SheetCurlLayout?
  private var sourceCover: CGImage?
  private var submittedProgress: Double?
  private var pageTextures: (leaf: any MTLTexture, base: any MTLTexture)?
  private var pageFold = SIMD4<Float>(1, 0, 0, 0)
  private let pagePass = MTLRenderPassDescriptor()
  private struct PageUniforms {
    var fold: SIMD4<Float>
    var paper: SIMD4<Float>
    var size: SIMD2<Float>
  }

  func pageDrawableBytes(width: Int, height: Int) throws -> Int {
    guard let device else { throw SceneRenderError.snapshotPending("page_device") }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = .renderTarget
    let allocation = device.heapTextureSizeAndAlign(descriptor: descriptor)
    let alignment = max(16 * 1024, allocation.align)
    return max(((allocation.size + alignment - 1) / alignment) * alignment,
      ((width * 4 + 255) / 256) * 256 * height)
  }

  #if os(iOS)
  func preparePages(leaf: PageTurnFrame, base: PageTurnFrame, operationID: UUID) throws {
    guard SheetCurlGPU.shared.pagePipeline != nil else { throw SceneRenderError.snapshotPending("page_pipeline") }
    cancelCoverContextSubscription()
    coverContextRequested = false
    retirePageExecution()
    if pageDrawableRequest == nil {
      try configurePageOutput(size: .init(width: leaf.texture.width, height: leaf.texture.height))
    }
    sourceCover = nil; coverImage = nil; sourceCoverFrame = nil
    pagePresentationGeneration &+= 1
    pageFrames = (leaf, base)
    pageOperationID = operationID; pageClockRequestedAt = nil
    pageUpdateMeasurement = nil
    pageMeasuredPublications = 0
    pageHasPublishedFrame = false
    pageAnimationTime = nil
    pagePose = nil; presentedPagePose = nil; pagePresentedSequence = -1; pagePresentedTime = nil
    pageTextures = (leaf.texture, base.texture)
    submittedProgress = nil
    // Exposure belongs to the first drawable's CA transaction. Only its
    // terminal OS receipt can admit subsequent asynchronous opaque frames.
    if onPageUpdateMeasured != nil {
      pageUpdateMeasurement = (pagePresentationGeneration, 6)
      measurePageUpdate(.prepared, info: UIUpdateInfo.current(for: self))
    }
  }

  /// Observes actual exposure, independently of GPU scheduling or OS receipts.
  private func measurePageExposure() {
    measurePageUpdate(.exposed, info: UIUpdateInfo.current(for: self))
  }

  private func measurePageUpdate(_ phase: PageUpdateTiming.Phase, info: UIUpdateInfo?,
    drawable: (any CAMetalDrawable)? = nil) {
    guard let measured = onPageUpdateMeasured, let operationID = pageOperationID,
      var measurement = pageUpdateMeasurement, measurement.generation == pagePresentationGeneration else { return }
    if phase == .beforeCommit || phase == .afterCommit {
      guard measurement.remainingPhases > 0 else { return }
      measurement.remainingPhases -= 1
      pageUpdateMeasurement = measurement
    }
    measured(.init(operationID: operationID, generation: pagePresentationGeneration, phase: phase,
      nextSequence: submittedFrameCount, recorded: CACurrentMediaTime(), modelTime: info?.modelTime,
      completionDeadline: info?.completionDeadlineTime, estimatedPresentation: info?.estimatedPresentationTime,
      viewHidden: isHidden, layerHidden: pageOutputLayer?.isHidden ?? true, windowAttached: window != nil,
      layerOpacity: pageOutputLayer?.opacity ?? 0,
      presentsWithTransaction: pageOutputLayer?.presentsWithTransaction ?? false,
      drawableMatchesLayer: drawable.map { $0.layer === pageOutputLayer },
      immediatePresentationExpected: info?.isImmediatePresentationExpected))
  }

  private func configurePageOutput(size: CGSize) throws {
    precondition(pageDrawableRequest == nil)
    if pageReclamationOwner == nil {
      pageReclamationOwner = SceneRenderResources.shared.registerReclamationOwner { [weak self] in
        self?.reclaimPageOutput() ?? []
      }
    }
    if pageOutput?.size != size {
      if let previous = pageOutput {
        pageOutput = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previous.layer.isHidden = true
        CATransaction.commit()
        drainPageOutput(previous, request: nil) { previous.release() }
      }
      guard let device else { throw SceneRenderError.snapshotPending("page_device") }
      let bytes = try pageDrawableBytes(width: Int(size.width), height: Int(size.height)) * drawableCount
      pageOutput = try SheetCurlPageOutput(device: device, size: size, bytes: bytes, count: drawableCount)
    }
    guard let pool = pageOutput else { return }
    pool.activate()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if pool.layer.superlayer == nil { layer.addSublayer(pool.layer) }
    pool.layer.frame = bounds
    pool.layer.isHidden = false
    pool.layer.presentsWithTransaction = true
    CATransaction.commit()
  }

  private func drainPageOutput(_ pool: SheetCurlPageOutput, request: SheetCurlDrawableRequest?,
    completion: @escaping () -> Void) {
    let retirement = SheetCurlPageRetirement(completion)
    if let request, request.holds(pool.reservation) {
      request.whenDrained { retirement.finishDrawable() }
    } else { retirement.finishDrawable() }
    if let fence = commandQueue?.makeCommandBuffer() {
      fence.addCompletedHandler { _ in Task { @MainActor in retirement.finishGPU() } }
      fence.commit()
    } else { retirement.finishGPU() }
  }

  private func reclaimPageOutput() -> [SceneResourceReclamationCandidate] {
    guard pageOperationID == nil, pageDrawableRequest == nil, let pool = pageOutput, pool.isIdle else { return [] }
    return [.init(id: pool.id, bytes: pool.reservation.byteCount, rasterCount: 0,
      value: .unused, distance: 0, restorationMilliseconds: 1, release: { [weak self, weak pool] in
        guard let self, let pool, self.pageOutput === pool, pool.isIdle, self.pageOperationID == nil,
          self.pageDrawableRequest == nil else { return nil }
        self.pageOutput = nil; pool.release()
        return nil
      })]
  }
  #endif

  func updatePage(progress: Double, anchor: Double, tilt: Double, layout: SheetCurlLayout) {
    guard pageTextures != nil else { return }
    let p = min(1, max(0, progress))
    var fold = SIMD4<Float>(1, 0, Float(p), 0)
    if p > 0, p < 1 {
      let travel = 2.35*p, dy = tilt*sin(.pi*p), length = hypot(travel, dy)
      let nx = travel/length, ny = -dy/length
      let radius = min(0.09, length*0.18)
      fold = .init(Float(nx), Float(ny), Float(nx+ny*anchor-(length + .pi*radius)*0.5), Float(radius))
    }
    guard self.progress != p || pageFold != fold || curlLayout != layout || submittedProgress == nil else {
      if framePending { requestFrame() }; return
    }
    self.progress = p; pageFold = fold; curlLayout = layout
    #if os(iOS)
    pagePoseRevision &+= 1
    pagePose = .init(progress: p, anchor: anchor, tilt: tilt)
    #endif
    framePending = true; requestFrame()
  }

  override init(frame frameRect: CGRect, device: (any MTLDevice)? = nil) {
    let gpu = SheetCurlGPU.shared
    let metalDevice = device ?? gpu.device
    commandQueue = gpu.commandQueue
    super.init(frame: frameRect, device: metalDevice)

    delegate = self
    framebufferOnly = false
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    enableSetNeedsDisplay = true
    isPaused = true
    autoResizeDrawable = true

    #if os(iOS)
      isOpaque = false
      backgroundColor = .clear
      layer.isOpaque = false
      (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    #elseif os(macOS)
      wantsLayer = true
      layer?.isOpaque = false
      layer?.backgroundColor = NSColor.clear.cgColor
      (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    #endif
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func prepareDrawable(size: CGSize) {
    #if os(iOS)
    if onDisplayUpdate != nil {
      configuringPageDrawable = true
      defer { configuringPageDrawable = false }
      retirePageExecution()
      if pageDrawableRequest != nil {
        // Every page-layer mutation waits for the old physical acquisition.
        pendingPageDrawableSize = size
        return
      }
      pendingPageDrawableSize = nil
      do { try configurePageOutput(size: size) }
      catch { failPageExecution(error); return }
      preparePageClock()
      return
    }
    #endif
    autoResizeDrawable = false
    if drawableSize != size { drawableSize = size }
    if let layer = layer as? CAMetalLayer, layer.drawableSize != size { layer.drawableSize = size }
  }

  func update(
    cover: CGImage,
    progress: Double,
    backsideColor: CoverBacksideColor,
    cornerRadius: CGFloat,
    layout: SheetCurlLayout
  ) {
    let resolvedProgress = CoverOpeningPhysics.clamped(progress)
    let changed =
      sourceCover.map { $0 !== cover } ?? true
      || self.progress != resolvedProgress
      || self.backsideColor != backsideColor
      || self.cornerRadius != cornerRadius
      || curlLayout != layout
    guard changed else {
      if framePending { requestFrame() }
      return
    }
    if sourceCover !== cover {
      pageTextures = nil
      #if os(iOS)
      pagePresentationGeneration &+= 1
      pageFrames = nil; sourceCoverFrame = nil; pageOperationID = nil; pageClockRequestedAt = nil
      #endif
      sourceCover = cover
      coverImage = CIImage(cgImage: cover)
      submittedProgress = nil
      presentsWithTransaction = onWillPresentFrame != nil
    }
    self.progress = resolvedProgress
    self.backsideColor = backsideColor
    self.cornerRadius = cornerRadius
    curlLayout = layout
    framePending = true
    requestFrame()
  }

  #if os(iOS)
  func update(cover: PageTurnFrame, progress: Double, backsideColor: CoverBacksideColor,
    cornerRadius: CGFloat, layout: SheetCurlLayout) {
    let resolvedProgress = CoverOpeningPhysics.clamped(progress)
    let changed = sourceCoverFrame !== cover || self.progress != resolvedProgress
      || self.backsideColor != backsideColor || self.cornerRadius != cornerRadius || curlLayout != layout
    guard changed else { if framePending { requestFrame() }; return }
    if sourceCoverFrame !== cover {
      guard let image = CIImage(mtlTexture: cover.texture, options: [.colorSpace: outputColorSpace]) else { return }
      pagePresentationGeneration &+= 1
      pageTextures = nil; pageFrames = nil; sourceCover = nil; pageOperationID = nil; pageClockRequestedAt = nil
      sourceCoverFrame = cover
      // Accepted frame textures use top-left sheet rows; the existing CI cover
      // curl consumes bottom-left image coordinates.
      coverImage = image.transformed(by: CGAffineTransform(translationX: 0, y: Double(cover.texture.height)).scaledBy(x: 1, y: -1))
      submittedProgress = nil; presentsWithTransaction = false
    }
    self.progress = resolvedProgress; self.backsideColor = backsideColor
    self.cornerRadius = cornerRadius; curlLayout = layout
    framePending = true; requestFrame()
  }
  #endif

  /// The cover owner keeps its real endpoint visible until this one shared
  /// program has finished its bitmap-to-BGRA GPU warmup. A page never calls it.
  @discardableResult func prepareCoverRendering() -> Bool {
    coverContextRequested = true
    if imageContext != nil { return true }
    guard coverContextFailure == nil else { return false }
    let gpu = SheetCurlGPU.shared
    if let result = gpu.preparedCoverContext {
      receiveCoverContext(result, notify: false)
      return imageContext != nil
    }
    guard window != nil else { return false }
    guard coverContextSubscription == nil else { return false }
    let id = UUID(); coverContextSubscription = id
    gpu.observeCover(id) { [weak self] result in
      guard let self, self.coverContextSubscription == id else { return }
      self.coverContextSubscription = nil
      self.receiveCoverContext(result, notify: true)
    }
    return false
  }

  private func receiveCoverContext(_ result: Result<CIContext, SceneRenderError>, notify: Bool) {
    switch result {
    case .success(let context):
      imageContext = context
      guard notify, window != nil, coverContextRequested else { return }
      onCoverRenderingReady?()
      if framePending, pageTextures == nil { requestFrame() }
    case .failure(let error):
      coverContextFailure = error
      framePending = false
      onCoverRenderFailure?(error)
    }
  }

  private func cancelCoverContextSubscription() {
    if let id = coverContextSubscription { SheetCurlGPU.shared.removeCoverObserver(id) }
    coverContextSubscription = nil
  }

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    guard onDisplayUpdate == nil else { return }
    framePending = true
    requestFrame()
  }

  #if os(iOS)
    override func layoutSubviews() {
      super.layoutSubviews()
      guard let output = pageOutputLayer, output.frame != bounds else { return }
      prepareDrawable(size: pendingPageDrawableSize ?? output.drawableSize)
      if framePending || animatesContinuously { requestFrame() }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { cancelCoverContextSubscription() }
      else if coverContextRequested, prepareCoverRendering() { onCoverRenderingReady?() }
      if window == nil, onDisplayUpdate != nil {
        // The operation owner resolves cancellation before its accepted pair
        // disappears. Reattaching cannot retain a motion with retired pixels.
        onPageDetached?()
        releaseSource()
      }
      // Register the one disabled clock with the mounted window, before input.
      // This neither obtains a drawable nor asks UIKit for continuous updates.
      if window != nil, onDisplayUpdate != nil { preparePageClock() }
      if window != nil, framePending { requestFrame() }
    }
  #elseif os(macOS)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { cancelCoverContextSubscription() }
      else if coverContextRequested, prepareCoverRendering() { onCoverRenderingReady?() }
      if window != nil, framePending { setNeedsDisplay(bounds) }
    }
  #endif

  func draw(in view: MTKView) {
    // A queued warm frame is still background work when a new contact arrives.
    // Keep it pending, without rescheduling a busy loop, until the next update.
    // UIKit also requests display during unrelated layer/layout transactions.
    // Those requests must not consume another drawable for the same cover.
    guard onDisplayUpdate == nil, framePending, window != nil, !isHidden, permitsFrameSubmission() else { return }
    guard coverImage != nil, prepareCoverRendering() else { return }
    autoreleasepool { submitPendingFrame() }
  }

  private func submitPendingFrame(drawable suppliedDrawable: (any CAMetalDrawable)? = nil,
    targetPresentation: TimeInterval = 0, renderingDeadline: TimeInterval = 0,
    displayUpdateReceived: TimeInterval? = nil) {
    let encodingBegan = onFrameMeasured == nil ? nil : CACurrentMediaTime()
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal { inFlightSemaphore.signal() }
    }

    let size = suppliedDrawable.map { CGSize(width: $0.texture.width, height: $0.texture.height) } ?? drawableSize
    guard size.width > 0,
      size.height > 0,
      let curlLayout,
      let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else { return }

    let canvasExtent = CGRect(origin: .zero, size: size)
    let sheetExtent = curlLayout.sheetExtent(inDrawableSize: size)
    let drawable: any CAMetalDrawable
    if pageTextures != nil {
      guard let suppliedDrawable else { return }
      drawable = suppliedDrawable
    } else {
      guard let currentDrawable else { return }
      drawable = currentDrawable
    }
    commandBuffer.label = pageTextures == nil ? "CoverCurl.draw" : "PageCurl.draw"
    if let pageTextures {
      guard let pipeline = SheetCurlGPU.shared.pagePipeline else { return }
      pagePass.colorAttachments[0].texture = drawable.texture
      pagePass.colorAttachments[0].loadAction = .dontCare
      pagePass.colorAttachments[0].storeAction = .store
      defer { pagePass.colorAttachments[0].texture = nil }
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pagePass) else { return }
      var uniforms = PageUniforms(fold: pageFold,
        paper: .init(Float(backsideColor.red), Float(backsideColor.green), Float(backsideColor.blue), 0.3),
        size: .init(Float(size.height/size.width), Float(1/size.width)))
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PageUniforms>.stride, index: 0)
      encoder.setFragmentTexture(pageTextures.leaf, index: 0)
      encoder.setFragmentTexture(pageTextures.base, index: 1)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      encoder.endEncoding()
    } else {
      guard let imageContext, let input = placedCoverImage(in: sheetExtent),
        let output = SheetCurlGPU.curlImage(input: input, backside: roundedBacksideImage(extent: sheetExtent),
          sheetExtent: sheetExtent, canvasExtent: canvasExtent, progress: progress,
          radius: CoverOpeningPhysics.curlRadius(for: sheetExtent)),
        clear(texture: drawable.texture, with: commandBuffer) else { return }
      imageContext.render(output, to: drawable.texture, commandBuffer: commandBuffer,
        bounds: canvasExtent, colorSpace: outputColorSpace)
    }
    let source = sourceCover, progress = progress
    #if os(iOS)
    let frames = pageFrames, coverFrame = sourceCoverFrame, operationID = pageOperationID, pose = pagePose
    let clockRequested = pageClockRequestedAt
    let presentationGeneration = pagePresentationGeneration
    #else
    let operationID: UUID? = nil, clockRequested: TimeInterval? = nil
    #endif
    let sequence = submittedFrameCount
    #if os(iOS)
    if let coverFrame, onCoverFrameReady != nil {
      NotebookMetalFrameReadiness.observe(drawable, commandBuffer: commandBuffer) { [weak self, coverFrame] readiness in
        guard let self, self.sourceCoverFrame === coverFrame else { return }
        if !readiness.isReady, self.progress == progress { self.framePending = true }
        self.onCoverFrameReady?(coverFrame, progress, sequence, readiness)
        self.resumePendingFrame()
      }
    }
    if let frames {
      NotebookMetalFrameReadiness.observe(drawable, commandBuffer: commandBuffer) { [weak self, frames] readiness in
        guard let self, self.pageOperationID == operationID,
          self.pagePresentationGeneration == presentationGeneration, self.pageFrames?.leaf === frames.leaf else { return }
        if case .awaitingOS(let submittedSequence, _) = self.pagePresentationPhase {
          if readiness.isReady {
            // Any exact-source successor can be the first shown drawable if
            // the reveal itself was dropped. This receipt changes mode only;
            // it never admits the next prepared frame.
            self.pagePresentationPhase = .motion
          } else if submittedSequence == sequence {
            self.pagePresentationPhase = .initial
            self.framePending = true
          }
        }
        if readiness.isReady, sequence > self.pagePresentedSequence,
          readiness.presentedTime == nil || self.pagePresentedTime == nil || readiness.presentedTime! > self.pagePresentedTime! {
          self.presentedPagePose = pose
          self.pagePresentedSequence = sequence
          self.pagePresentedTime = readiness.presentedTime
        }
        if !readiness.isReady, self.progress == progress { self.framePending = true }
        self.onPageFrameReady?(frames.leaf, progress, sequence, readiness)
        if self.animatesContinuously || self.framePending || self.pagePublication != nil { self.requestFrame() }
      }
    }
    // Keep both immutable cuts charged through the final sampling command.
    commandBuffer.addCompletedHandler { [frames, coverFrame] _ in _ = (frames, coverFrame) }
    #endif
    let submitted = encodingBegan.map { _ in CACurrentMediaTime() }
    if let source, onFrameReady != nil || onFramePresented != nil {
      NotebookMetalFrameReadiness.observe(drawable,commandBuffer:commandBuffer) { [weak self] readiness in
        guard let self, sourceCover === source else { return }
        if !readiness.isReady,self.progress == progress { framePending=true }
        onFrameReady?(source,progress,sequence,readiness)
        if let time=readiness.presentedTime { onFramePresented?(source,progress,time) }
        resumePendingFrame()
      }
    }
    #if os(iOS)
    let scheduleTiming = encodingBegan != nil || frames != nil ? SheetCurlScheduleTiming() : nil
    #else
    let scheduleTiming = encodingBegan.map { _ in SheetCurlScheduleTiming() }
    #endif
    if let scheduleTiming { commandBuffer.addScheduledHandler { _ in scheduleTiming.record() } }
    let needsCompletionDelivery = onFrameMeasured != nil || onDisplayUpdate == nil
    #if os(iOS)
    let outputLease = frames == nil ? frameLease : pageOutput?.reservation
    #else
    let outputLease = frameLease
    #endif
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore, outputLease] command in
      _ = outputLease // Keep the charged image/drawables through GPU completion.
      // The UIKit page clock owns presentation pacing. Holding an encoding
      // slot until the OS presentation callback double-throttles it and drops
      // admitted 120 Hz updates even after their GPU work has completed.
      inFlightSemaphore.signal()
      // An active page clock already retries pending frames. Only diagnostics
      // and event-driven covers need a second MainActor callback here.
      #if os(iOS)
      let failedPage = frames != nil && command.status != .completed
      #else
      let failedPage = false
      #endif
      guard needsCompletionDelivery || failedPage else { return }
      let timing = encodingBegan.map { began in
        FrameTiming(operationID: operationID, sequence: sequence, clockRequested: clockRequested,
          displayUpdateReceived: displayUpdateReceived, encodingBegan: began, submitted: submitted!, gpuBegan: command.gpuStartTime,
          gpuEnded: command.gpuEndTime, renderingDeadline: renderingDeadline,
          targetPresentation: targetPresentation, scheduled: scheduleTiming?.value)
      }
      Task { @MainActor [weak self] in
        #if os(iOS)
        let isCurrent = coverFrame != nil ? self?.sourceCoverFrame === coverFrame
          : (source != nil ? self?.sourceCover === source
            : self?.pageOperationID == operationID && self?.pagePresentationGeneration == presentationGeneration
              && self?.pageFrames?.leaf.id == frames?.leaf.id)
        #else
        let isCurrent = self?.sourceCover === source
        #endif
        if let timing, isCurrent { self?.onFrameMeasured?(timing) }
        #if os(iOS)
        if failedPage, isCurrent {
          self?.failPageExecution(SceneRenderError.snapshotPending("page_gpu")); return
        }
        #endif
        self?.resumePendingFrame()
      }
    }
    mustSignal = false
    // A flat curl fully covers its live paper. Install that same paper below
    // it before the frame can be shown, not in its later presentation callback.
    // Leaving the flat boundary restores the other leaf in the same transaction.
    let updatesUnderlay = onWillPresentFrame != nil && (submittedProgress == nil
      || (submittedProgress == 0) != (progress == 0))
    #if os(iOS)
    if frames != nil, let operationID, let scheduleTiming {
      // A direct Metal callback marks scheduling. BeforeCommit consumes that
      // receipt with a deadline-bounded fence, without a worker-to-main task.
      pagePublication = .init(operationID: operationID, generation: presentationGeneration,
        drawable: drawable, command: commandBuffer, schedule: scheduleTiming,
        poseRevision: pagePoseRevision, sequence: sequence)
      commandBuffer.commit()
      submittedProgress = progress; framePending = false; submittedFrameCount += 1
      return
    }
    #endif
    // Keep this mode for the whole source. A later display-link callback must
    // not detach presentation from an earlier, still-open UIKit transaction.
    if presentsWithTransaction {
      commandBuffer.commit()
      commandBuffer.waitUntilScheduled()
      CATransaction.begin(); CATransaction.setDisableActions(true)
      if updatesUnderlay, let source { onWillPresentFrame?(source, progress) }
      drawable.present()
      CATransaction.commit()
    } else {
      // commit() is not a scheduling fence. Let Metal register the drawable's
      // writes before presenting it; otherwise a recycled/clear image can win.
      commandBuffer.present(drawable)
      commandBuffer.commit()
    }
    submittedProgress = progress
    framePending = false
    submittedFrameCount += 1
  }

  private func resumePendingFrame() {
    guard framePending, window != nil, permitsFrameSubmission() else { return }
    guard onDisplayUpdate != nil || !isHidden else { return }
    requestFrame()
  }

  private func requestFrame() {
    #if os(iOS)
      if onDisplayUpdate != nil {
        if onFrameMeasured != nil, pageClockRequestedAt == nil { pageClockRequestedAt = CACurrentMediaTime() }
        guard !configuringPageDrawable, pendingPageDrawableSize == nil, permitsFrameSubmission(), window != nil,
          let output = pageOutputLayer, output.drawableSize.width > 0, output.drawableSize.height > 0 else { return }
        preparePageClock()
        requestPageDrawable()
        pageUIUpdates?.isEnabled = true
        return
      }
    #endif
    guard coverImage != nil, prepareCoverRendering() else { return }
    setNeedsDisplay(bounds)
  }

  #if os(iOS)
  private func preparePageClock() {
    guard pageUIUpdates == nil else { return }
    let rate = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 120)
    let updates = UIUpdateLink(view: self)
    // Released motion depends only on the update's time. Encode before UIKit
    // waits for input, giving Metal the available scheduling interval. Contact
    // changes still use afterEventDispatch and can supersede that early pose.
    updates.addAction(to: .afterUpdateScheduled) { [weak self] _, info in
      guard let self, self.animatesContinuously else { return }
      self.preparePageUpdate(info)
    }
    updates.addAction(to: .afterEventDispatch) { [weak self] _, info in self?.preparePageUpdate(info) }
    updates.addAction(to: .beforeCATransactionCommit) { [weak self] _, info in
      self?.publishPageUpdate(info)
      self?.measurePageUpdate(.beforeCommit, info: info)
    }
    updates.addAction(to: .afterCATransactionCommit) { [weak self] _, info in
      self?.measurePageUpdate(.afterCommit, info: info)
      self?.finishPageUpdate()
    }
    updates.requiresContinuousUpdates = true
    updates.preferredFrameRateRange = .init(minimum: rate, maximum: rate, preferred: rate)
    updates.wantsImmediatePresentation = true
    updates.isEnabled = false
    pageUIUpdates = updates
  }

  private func requestPageDrawable() {
    // The charged three-drawable pool bounds all submitted pixels. Keep at
    // most one physical acquisition and one prepared publication; a delayed
    // OS callback cannot become a second, serial frame-admission clock.
    guard pageDrawableRequest == nil, pagePublication == nil || animatesContinuously || framePending,
      pageOperationID != nil, window != nil, permitsFrameSubmission(), let layer = pageOutputLayer else { return }
    let request = SheetCurlDrawableRequest(layer: layer, reservation: pageOutput?.reservation)
    let generation = pagePresentationGeneration
    pageDrawableRequest = request
    request.start { [weak self, weak request] in
      guard let self, let request, self.pageDrawableRequest === request else { return }
      if request.isCancelled || self.pagePresentationGeneration != generation {
        self.pageDrawableRequest = nil
        if let size = self.pendingPageDrawableSize { self.prepareDrawable(size: size) }
        if self.animatesContinuously || self.framePending { self.requestFrame() }
        return
      }
      if request.hasFailed {
        failPageExecution(SceneRenderError.snapshotPending("page_drawable"))
      }
    }
  }

  private func preparePageUpdate(_ info: UIUpdateInfo) {
    guard window != nil, permitsFrameSubmission(), pageOperationID != nil else { retirePageExecution(); return }
    if let publication = pagePublication, publication.poseRevision != pagePoseRevision {
      // Input accepted after the early animation phase owns the next visible
      // pose. The obsolete command may finish on the GPU, but cannot publish
      // over a regrab or a newer held-contact position in this same UI update.
      pagePublication = nil
    }
    // A late scheduled command keeps its accepted pose until this clock can
    // publish it. Never advance to a pose for which no drawable is available.
    guard pagePublication == nil else { return }
    guard let drawable = pageDrawableRequest?.take() else { requestPageDrawable(); return }
    pageDrawableRequest = nil
    guard let output = pageOutputLayer, drawable.layer === output,
      drawable.texture.width == Int(output.drawableSize.width), drawable.texture.height == Int(output.drawableSize.height) else {
      failPageExecution(SceneRenderError.snapshotPending("page_drawable_geometry")); return
    }
    // Immediate presentation can change UIKit's estimate between updates.
    // That policy change cannot rewind an already accepted physical pose.
    let animationTime = max(pageAnimationTime ?? info.estimatedPresentationTime, info.estimatedPresentationTime)
    pageAnimationTime = animationTime
    onDisplayUpdate?(animationTime)
    guard window != nil, permitsFrameSubmission(), pageOperationID != nil else { return }
    if framePending {
      autoreleasepool { submitPendingFrame(drawable: drawable, targetPresentation: info.estimatedPresentationTime,
        renderingDeadline: info.completionDeadlineTime,
        displayUpdateReceived: onFrameMeasured == nil ? nil : CACurrentMediaTime()) }
    }
    if animatesContinuously || framePending { requestPageDrawable() }
  }

  private func publishPageUpdate(_ info: UIUpdateInfo) {
    guard let publication = pagePublication else { return }
    guard window != nil, permitsFrameSubmission(), pageOperationID == publication.operationID,
      pagePresentationGeneration == publication.generation,
      publication.drawable.layer === pageOutputLayer else { retirePageExecution(); return }
    guard publication.poseRevision == pagePoseRevision else { pagePublication = nil; return }
    if publication.command.status == .error {
      failPageExecution(SceneRenderError.snapshotPending("page_gpu")); return
    }
    guard publication.schedule.waitForScheduling(completionDeadline: info.completionDeadlineTime) else { return }
    let revealsPage: Bool
    if case .initial = pagePresentationPhase { revealsPage = true } else { revealsPage = false }
    if revealsPage {
      pageOutputLayer?.presentsWithTransaction = true
      CATransaction.begin(); CATransaction.setDisableActions(true)
    }
    defer { if revealsPage { CATransaction.commit() } }
    if !pageHasPublishedFrame {
      onPageFrameWillPresent?(publication.operationID)
      guard pageOperationID == publication.operationID, pagePresentationGeneration == publication.generation else {
        return
      }
      isHidden = false
      measurePageExposure()
      pageHasPublishedFrame = true
    }
    let measuresPublication = onPageUpdateMeasured != nil && pageMeasuredPublications < 3
    if measuresPublication { measurePageUpdate(.beforePresent, info: info, drawable: publication.drawable) }
    publication.drawable.present()
    if revealsPage {
      pagePresentationPhase = .awaitingOS(sequence: publication.sequence, drawable: publication.drawable)
    }
    if measuresPublication {
      measurePageUpdate(.afterPresent, info: info, drawable: publication.drawable)
      pageMeasuredPublications += 1
    }
    pagePublication = nil
  }

  private func finishPageUpdate() {
    if case .motion = pagePresentationPhase {
      // The exact OS receipt permits asynchronous motion, but only this CA
      // owner ends transactional mode after all publications in the current
      // update committed. It cannot detach a queued successor's transaction.
      pageOutputLayer?.presentsWithTransaction = false
    }
    if !animatesContinuously, !framePending, pagePublication == nil {
      cancelPageDrawableRequest()
      pageUIUpdates?.isEnabled = false
    }
  }

  private func failPageExecution(_ error: Error) {
    framePending = false
    retirePageExecution()
    onPageRenderFailure?(error)
  }

  private func retirePageExecution() {
    cancelPageDrawableRequest()
    pagePublication = nil
    pagePresentationPhase = .initial
    pageUIUpdates?.isEnabled = false
  }

  private func cancelPageDrawableRequest() {
    // nextDrawable itself is not cancellable. Keep at most this one blocked
    // worker for the physical layer; a successor demand starts when it drains,
    // rather than accumulating a worker and two reservations per cancelled turn.
    if pageDrawableRequest?.cancel() == true { pageDrawableRequest = nil }
  }

  isolated deinit {
    releaseSource()
    if let pageReclamationOwner { SceneRenderResources.shared.unregisterReclamationOwner(pageReclamationOwner) }
  }
  #endif

  #if os(macOS)
  isolated deinit { cancelCoverContextSubscription() }
  #endif

  private func clear(
    texture: any MTLTexture,
    with commandBuffer: any MTLCommandBuffer
  ) -> Bool {
    let descriptor = MTLRenderPassDescriptor()
    guard let attachment = descriptor.colorAttachments[0] else {
      return false
    }
    attachment.texture = texture
    attachment.loadAction = .clear
    attachment.storeAction = .store
    attachment.clearColor = clearColor
    guard
      let encoder = commandBuffer.makeRenderCommandEncoder(
        descriptor: descriptor
      )
    else { return false }
    encoder.endEncoding()
    return true
  }

  private func placedCoverImage(in sheetExtent: CGRect) -> CIImage? {
    guard let coverImage else { return nil }
    let source = coverImage.extent.size
    guard source.width > 0, source.height > 0 else { return nil }
    let scaled = coverImage.transformed(
      by: CGAffineTransform(
        scaleX: sheetExtent.width / source.width,
        y: sheetExtent.height / source.height
      )
    )
    return scaled.transformed(
      by: CGAffineTransform(
        translationX: sheetExtent.minX - scaled.extent.minX,
        y: sheetExtent.minY - scaled.extent.minY
      )
    ).cropped(
      to: sheetExtent
    )
  }

  private func roundedBacksideImage(extent: CGRect) -> CIImage {
    let color = CIImage(color: backsideColor.ciColor).cropped(to: extent)
    let radius = cornerRadius * extent.width / curlLayoutSheetWidth
    guard radius > 0 else { return color }
    let generator = CIFilter.roundedRectangleGenerator()
    generator.extent = extent
    generator.radius = Float(max(0, radius))
    generator.color = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
    guard let mask = generator.outputImage?.cropped(to: extent) else {
      return color
    }
    return color.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
        kCIInputMaskImageKey: mask,
      ]
    )
  }

  private var curlLayoutSheetWidth: CGFloat {
    max(curlLayout?.sheetSize.width ?? 0, 1)
  }
}

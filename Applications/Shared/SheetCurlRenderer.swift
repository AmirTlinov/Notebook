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
  let imageContext: CIContext?
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
    imageContext = device.map {
      CIContext(
        mtlDevice: $0,
        options: [
          .cacheIntermediates: false,
          .workingColorSpace: NSNull(),
        ]
      )
    }
    let imageContext = imageContext, commandQueue = commandQueue
    DispatchQueue.global(qos: .userInitiated).async {
      Self.prepareCurlProgram(in: imageContext, queue: commandQueue)
    }
  }

  private static func prepareCurlProgram(in context: CIContext?, queue: (any MTLCommandQueue)?) {
    guard let context, let queue,
      let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(extent)
    guard let pixels = bitmap.makeImage() else { return }
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
        sheetExtent: extent, canvasExtent: extent, progress: 0.1, radius: 2.24) else { return }
    context.render(output, to: texture, commandBuffer: command, bounds: extent,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    command.commit()
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

/// Optional timing storage shared only by Metal's scheduled/completed callbacks.
/// This observes submission without adding a publication queue or actor hop.
private final class SheetCurlScheduleTiming: @unchecked Sendable {
  private let lock = NSLock()
  private var timestamp: TimeInterval?
  func record() { lock.withLock { timestamp = CACurrentMediaTime() } }
  var value: TimeInterval? { lock.withLock { timestamp } }
}

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
  let drawableCount = 2
  var frameLease: RasterReservation?
  /// Display-only instrumentation; Simulator never sends this callback.
  var onFramePresented: ((CGImage, Double, TimeInterval) -> Void)?
  var onFrameReady: ((CGImage, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  #if os(iOS)
  var onPageFrameReady: ((PageTurnFrame, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  var onCoverFrameReady: ((PageTurnFrame, Double, Int, NotebookMetalFrameReadiness) -> Void)?
  private var sourceCoverFrame: PageTurnFrame?
  private var pageFrames: (leaf: PageTurnFrame, base: PageTurnFrame)?
  private var pageOperationID: UUID?
  private var pageClockRequestedAt: TimeInterval?
  private var pagePresentationGeneration: UInt64 = 0
  #endif
  /// Source reveal and the flat-sheet boundary share their drawable's CA
  /// transaction. The native owner installs the paper beneath that exact frame.
  var onWillPresentFrame: ((CGImage, Double) -> Void)?
  // An opt-in, bounded diagnostic at the actual submission owner. It does not
  // alter admission, clock, command ordering or the presentation receipt.
  var onFrameMeasured: ((FrameTiming) -> Void)?
  /// Page motion and its drawable share the system's Metal presentation clock.
  /// Covers are event-driven and do not install a second animation clock.
  var onDisplayUpdate: ((TimeInterval) -> Void)?
  var animatesContinuously = false {
    didSet { if animatesContinuously { requestFrame() } }
  }
  #if os(iOS)
    private var displayLink: CAMetalDisplayLink?
    private var pageUIUpdates: UIUpdateLink?
  #endif

  func releaseSource(presented: Bool = false) {
    animatesContinuously = false
    sourceCover = nil; coverImage = nil; pageTextures = nil; framePending = false
    #if os(iOS)
    pagePresentationGeneration &+= 1
    pageFrames = nil; sourceCoverFrame = nil; pageOperationID = nil; pageClockRequestedAt = nil
    #endif
    let lease = frameLease
    frameLease = nil
    #if os(iOS)
    displayLink?.isPaused = true
    pageUIUpdates?.isEnabled = false
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
  private let imageContext: CIContext?
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
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat,
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
    sourceCover = nil; coverImage = nil; sourceCoverFrame = nil
    pagePresentationGeneration &+= 1
    pageFrames = (leaf, base)
    pageOperationID = operationID; pageClockRequestedAt = nil
    pageTextures = (leaf.texture, base.texture)
    submittedProgress = nil
    presentsWithTransaction = false
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
    framePending = true; requestFrame()
  }

  override init(frame frameRect: CGRect, device: (any MTLDevice)? = nil) {
    let gpu = SheetCurlGPU.shared
    let metalDevice = device ?? gpu.device
    commandQueue = gpu.commandQueue
    imageContext = gpu.imageContext
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
    autoResizeDrawable = false
    #if os(iOS)
    displayLink?.isPaused = true
    #endif
    if drawableSize != size { drawableSize = size }
    if let layer = layer as? CAMetalLayer, layer.drawableSize != size { layer.drawableSize = size }
    #if os(iOS)
    if onDisplayUpdate != nil { preparePageClock() }
    #endif
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

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    framePending = true
    requestFrame()
  }

  #if os(iOS)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        pagePresentationGeneration &+= 1
        if pageFrames != nil { framePending = true }
        displayLink?.invalidate(); displayLink = nil
        pageUIUpdates?.isEnabled = false
      }
      // Register the one paused clock with the mounted window, before input.
      // This neither obtains a drawable nor asks UIKit for continuous updates.
      if window != nil, onDisplayUpdate != nil { preparePageClock() }
      if window != nil, framePending { requestFrame() }
    }
  #elseif os(macOS)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil, framePending { setNeedsDisplay(bounds) }
    }
  #endif

  func draw(in view: MTKView) {
    // A queued warm frame is still background work when a new contact arrives.
    // Keep it pending, without rescheduling a busy loop, until the next update.
    // UIKit also requests display during unrelated layer/layout transactions.
    // Those requests must not consume another drawable for the same cover.
    guard onDisplayUpdate == nil, framePending, window != nil, !isHidden, permitsFrameSubmission() else { return }
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

    guard drawableSize.width > 0,
      drawableSize.height > 0,
      let curlLayout,
      let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else { return }

    let size = suppliedDrawable.map { CGSize(width: $0.texture.width, height: $0.texture.height) } ?? drawableSize
    let canvasExtent = CGRect(origin: .zero, size: size)
    let sheetExtent = curlLayout.sheetExtent(inDrawableSize: size)
    guard let drawable = suppliedDrawable ?? currentDrawable else { return }
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
    let frames = pageFrames, coverFrame = sourceCoverFrame, operationID = pageOperationID
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
    if let frames, onPageFrameReady != nil {
      NotebookMetalFrameReadiness.observe(drawable, commandBuffer: commandBuffer) { [weak self, frames] readiness in
        guard let self, self.pageOperationID == operationID,
          self.pagePresentationGeneration == presentationGeneration, self.pageFrames?.leaf === frames.leaf else { return }
        if !readiness.isReady, self.progress == progress { self.framePending = true }
        self.onPageFrameReady?(frames.leaf, progress, sequence, readiness)
        self.resumePendingFrame()
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
    let scheduleTiming = encodingBegan.map { _ in SheetCurlScheduleTiming() }
    if let scheduleTiming { commandBuffer.addScheduledHandler { _ in scheduleTiming.record() } }
    let needsCompletionDelivery = onFrameMeasured != nil || onDisplayUpdate == nil
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore, frameLease] command in
      _ = frameLease // Keep the charged image/drawables through GPU completion.
      // The page clock already owns presentation pacing. Holding an encoding
      // slot until the OS presentation callback double-throttles it and drops
      // admitted 120 Hz updates even after their GPU work has completed.
      inFlightSemaphore.signal()
      // An active page clock already retries pending frames. Only diagnostics
      // and event-driven covers need a second MainActor callback here.
      guard needsCompletionDelivery else { return }
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
        self?.resumePendingFrame()
      }
    }
    mustSignal = false
    // A flat curl fully covers its live paper. Install that same paper below
    // it before the frame can be shown, not in its later presentation callback.
    // Leaving the flat boundary restores the other leaf in the same transaction.
    let updatesUnderlay = onWillPresentFrame != nil && (submittedProgress == nil
      || (submittedProgress == 0) != (progress == 0))
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
    guard framePending, window != nil, !isHidden, permitsFrameSubmission() else { return }
    requestFrame()
  }

  private func requestFrame() {
    #if os(iOS)
      if onDisplayUpdate != nil {
        if onFrameMeasured != nil, pageClockRequestedAt == nil { pageClockRequestedAt = CACurrentMediaTime() }
        guard permitsFrameSubmission(), window != nil, !isHidden, drawableSize.width > 0, drawableSize.height > 0,
          layer is CAMetalLayer else { return }
        preparePageClock()
        displayLink?.isPaused = false
        pageUIUpdates?.isEnabled = true
        return
      }
    #endif
    setNeedsDisplay(bounds)
  }

  #if os(iOS)
  private func preparePageClock() {
    guard displayLink == nil, let layer = layer as? CAMetalLayer else { return }
    let link = CAMetalDisplayLink(metalLayer: layer)
    link.delegate = self; link.preferredFrameLatency = 1
    let rate = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 120)
    link.preferredFrameRateRange = .init(minimum: rate, maximum: rate, preferred: rate)
    link.isPaused = true
    displayLink = link
    link.add(to: .main, forMode: .common)
    if pageUIUpdates == nil {
      let updates = UIUpdateLink(view: self)
      updates.addAction(to: .afterUpdateComplete) { _, _ in }
      updates.wantsImmediatePresentation = true
      updates.isEnabled = false
      pageUIUpdates = updates
    }
  }
  isolated deinit { displayLink?.invalidate(); pageUIUpdates?.isEnabled = false }
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

#if os(iOS)
extension SheetCurlMetalView: @preconcurrency CAMetalDisplayLinkDelegate {
  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    let received = onFrameMeasured == nil ? nil : CACurrentMediaTime()
    guard link === displayLink else { return }
    guard window != nil, !isHidden, permitsFrameSubmission() else {
      link.isPaused = true; pageUIUpdates?.isEnabled = false
      return
    }
    onDisplayUpdate?(update.targetPresentationTimestamp)
    if framePending {
      autoreleasepool { submitPendingFrame(drawable: update.drawable, targetPresentation: update.targetPresentationTimestamp,
        renderingDeadline: update.targetTimestamp, displayUpdateReceived: received) }
    }
    if !animatesContinuously && !framePending {
      link.isPaused = true; pageUIUpdates?.isEnabled = false
    }
  }
}
#endif

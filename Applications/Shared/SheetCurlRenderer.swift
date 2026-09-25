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

/// One shared Core Image executor compiles the physical curl before a finger
/// can ask for it. Individual covers keep their own drawable and in-flight
/// limit, while the expensive Metal context and filter program are prepared
/// once outside the interactive frame.
private final class SheetCurlGPU: @unchecked Sendable {
  static let shared = SheetCurlGPU()

  let device: (any MTLDevice)?
  let commandQueue: (any MTLCommandQueue)?
  let imageContext: CIContext?

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
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

/// GPU executor for the physical sheet. Core Image owns curl geometry and
/// backside illumination; this view supplies the frozen cover pixels, clears
/// every drawable, and presents the camera-owned progress value.
@MainActor
final class SheetCurlMetalView: MTKView, MTKViewDelegate {
  struct FrameTiming: Sendable {
    let encodingBegan, submitted, gpuBegan, gpuEnded, targetPresentation: TimeInterval
  }
  var permitsFrameSubmission: @MainActor () -> Bool = { false }
  private(set) var submittedFrameCount = 0
  let drawableCount = 2
  var frameLease: RasterReservation?
  struct FrameResolution: Sendable {
    let ordinal: Int
    let completion: MetalFrameCompletion
  }
  var onFrameResolved: ((CGImage, Double, FrameResolution) -> Void)?
  /// The first drawable and its native z-order enter the same CA transaction.
  /// Waiting for display before exposing an occluded layer can deadlock a held turn.
  var onWillPresentSource: ((CGImage) -> Void)?
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
  #endif

  func releaseSource(presented: Bool = false) {
    #if os(iOS)
      displayLink?.invalidate(); displayLink = nil
    #endif
    animatesContinuously = false
    sourceCover = nil; coverImage = nil; framePending = false
    guard let lease = frameLease else { return }
    frameLease = nil
    // The view is reused, but idle/cancelled turns do not retain its drawable
    // backing. Submitted commands still own their textures until the fence.
    releaseDrawables()
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
  private var sourceNeedsReveal = false

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
    drawableSize = size
    // The page's CAMetalDisplayLink acquires from the actual layer without
    // invoking MetalKit's draw(), which otherwise applies this pending resize.
    // Update both at the same owner before enabling the presentation clock.
    (layer as? CAMetalLayer)?.drawableSize = size
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
      sourceCover = cover
      coverImage = CIImage(cgImage: cover)
      sourceNeedsReveal = onWillPresentSource != nil
      presentsWithTransaction = sourceNeedsReveal
    }
    self.progress = resolvedProgress
    self.backsideColor = backsideColor
    self.cornerRadius = cornerRadius
    curlLayout = layout
    framePending = true
    requestFrame()
  }

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
    targetPresentation: TimeInterval = 0) {
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
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let imageContext
    else { return }

    let size = suppliedDrawable.map { CGSize(width: $0.texture.width, height: $0.texture.height) } ?? drawableSize
    let canvasExtent = CGRect(origin: .zero, size: size)
    let sheetExtent = curlLayout.sheetExtent(inDrawableSize: size)
    guard let input = placedCoverImage(in: sheetExtent) else { return }
    let radius = curlLayout.clipsToSheet ? Float(min(sheetExtent.width, sheetExtent.height) * 0.035)
      : CoverOpeningPhysics.curlRadius(for: sheetExtent)
    // CIPageCurlWithShadowTransition's cast shadow includes its opaque output
    // extent. The fold's own lighting is the visual owner while the sheet moves,
    // so these values keep the surrounding Metal canvas transparent.
    // Build the graph before borrowing a drawable. All temporary Core Image /
    // Metal references leave this frame's autorelease pool after submission,
    // not after every other view has drawn in the same layer transaction.
    guard let output = SheetCurlGPU.curlImage(input: input, backside: roundedBacksideImage(extent: sheetExtent),
      sheetExtent: sheetExtent, canvasExtent: canvasExtent, progress: progress, radius: radius),
      let drawable = suppliedDrawable ?? currentDrawable
    else {
      return
    }
    guard clear(texture: drawable.texture, with: commandBuffer) else {
      return
    }
    imageContext.render(
      output,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: canvasExtent,
      colorSpace: outputColorSpace
    )
    let source = sourceCover!, progress = progress
    let submitted = encodingBegan.map { _ in CACurrentMediaTime() }
    if onFrameResolved != nil {
      let ordinal = submittedFrameCount
      MetalFrameCompletion.observe(drawable, after: commandBuffer) { [weak self] completion in
        Task { @MainActor [weak self] in
          // A dropped drawable is NOT a landing receipt. Retry the latest
          // required image, including a terminal image, on the same clock.
          guard let self, self.sourceCover === source else { return }
          if !completion.permitsProgress, self.progress == progress { self.framePending = true }
          self.onFrameResolved?(source, progress, .init(ordinal: ordinal, completion: completion))
          self.resumePendingFrame()
        }
      }
    }
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore, frameLease] command in
      _ = frameLease // Keep the charged image/drawables through GPU completion.
      // The display link already owns presentation pacing. Holding an encoding
      // slot until the OS presentation callback double-throttles it and drops
      // admitted 120 Hz updates even after their GPU work has completed.
      inFlightSemaphore.signal()
      let timing = encodingBegan.map { began in
        FrameTiming(encodingBegan: began, submitted: submitted!, gpuBegan: command.gpuStartTime,
          gpuEnded: command.gpuEndTime, targetPresentation: targetPresentation)
      }
      Task { @MainActor [weak self] in
        if let timing, self?.sourceCover === source { self?.onFrameMeasured?(timing) }
        self?.resumePendingFrame()
      }
    }
    mustSignal = false
    if sourceNeedsReveal {
      commandBuffer.commit()
      commandBuffer.waitUntilScheduled()
      CATransaction.begin(); CATransaction.setDisableActions(true)
      onWillPresentSource?(source)
      drawable.present()
      CATransaction.commit()
      sourceNeedsReveal = false
    } else if suppliedDrawable != nil {
      commandBuffer.commit()
      drawable.present()
    } else {
      commandBuffer.present(drawable)
      commandBuffer.commit()
    }
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
        guard permitsFrameSubmission(), window != nil, !isHidden, drawableSize.width > 0, drawableSize.height > 0,
          let layer = layer as? CAMetalLayer else { return }
        if displayLink == nil {
          let link = CAMetalDisplayLink(metalLayer: layer)
          link.delegate = self
          link.preferredFrameLatency = 1
          let rate = Float(window?.screen.maximumFramesPerSecond ?? 60)
          link.preferredFrameRateRange = .init(minimum: rate, maximum: rate, preferred: rate)
          displayLink = link
          link.add(to: .main, forMode: .common)
        }
        displayLink?.isPaused = false
        return
      }
    #endif
    setNeedsDisplay(bounds)
  }

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
    guard link === displayLink, window != nil, !isHidden, permitsFrameSubmission() else {
      link.isPaused = true
      return
    }
    onDisplayUpdate?(update.targetPresentationTimestamp)
    if framePending {
      autoreleasepool { submitPendingFrame(drawable: update.drawable, targetPresentation: update.targetPresentationTimestamp) }
    }
    if !sourceNeedsReveal { presentsWithTransaction = false }
    if !animatesContinuously && !framePending { link.isPaused = true }
  }
}
#endif

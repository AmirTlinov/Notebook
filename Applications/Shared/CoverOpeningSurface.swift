import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import NotebookCore
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// The one visual owner of a cover while a notebook or document opens.
///
/// The board camera owns `progress`. This surface turns that same value into a
/// reversible Core Image page curl, so a pinch can move the cover in either
/// direction without handing the gesture to a second animation.
struct CoverOpeningSurface<Cover: View>: View {
  @Environment(NotebookAppModel.self) private var model

  let ownerID: UUID
  let progress: Double
  let revision: CoverRenderingRevision
  let backsideColor: CoverBacksideColor
  let cover: Cover

  init(
    ownerID: UUID,
    progress: Double,
    revision: CoverRenderingRevision,
    backsideColor: CoverBacksideColor,
    @ViewBuilder cover: () -> Cover
  ) {
    self.ownerID = ownerID
    self.progress = progress
    self.revision = revision
    self.backsideColor = backsideColor
    self.cover = cover()
  }

  var body: some View {
    PlatformCoverOpeningSurface(
      ownerID: ownerID,
      progress: progress,
      revision: revision,
      backsideColor: backsideColor,
      cornerRadius: NotebookGeometry.cornerRadius,
      cover: AnyView(cover.environment(model))
    )
    .allowsHitTesting(progress < CoverOpeningPhysics.liveCoverLimit)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("cover-opening-surface")
    .accessibilityValue(
      "Обложка \(Int((CoverOpeningPhysics.clamped(progress) * 100).rounded()))%"
    )
  }
}

struct CoverRenderingRevision: Equatable {
  struct ElementRevision: Equatable {
    let id: String
    let stamp: VersionStamp
  }

  struct InkRevision: Equatable {
    let id: UUID
    let stamp: VersionStamp
    let stateStamp: VersionStamp
  }

  let title: String
  let elements: [ElementRevision]
  let ink: [InkRevision]

  init(
    item: WorkspaceItem,
    elements: [SpatialElement],
    journal: SpatialInkJournal?
  ) {
    title = item.title
    self.elements = elements.map {
      ElementRevision(id: $0.id, stamp: $0.stamp)
    }
    let surface = SurfaceID.cover(item.id)
    ink =
      journal?.actions.compactMap { action in
        guard action.spans.contains(where: { $0.surface == surface }) else {
          return nil
        }
        return InkRevision(
          id: action.id,
          stamp: action.stamp,
          stateStamp: action.stateStamp
        )
      } ?? []
  }
}

struct CoverBacksideColor: Equatable {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat

  static let notebook = CoverBacksideColor(
    red: 0.965,
    green: 0.955,
    blue: 0.915
  )

  static let document = CoverBacksideColor(
    red: 0.978,
    green: 0.972,
    blue: 0.942
  )

  var ciColor: CIColor {
    CIColor(red: red, green: green, blue: blue, alpha: 1)
  }
}

enum CoverOpeningPhysics {
  static let endpointTolerance = 0.001
  static let liveCoverLimit = 0.001
  static let warmCoverOpacity: CGFloat = 0.001
  static let curlRadiusRatio = 0.075
  static let shadowHandoffProgress = 0.08
  static let systemShadowSize: Float = 0
  static let systemShadowAmount: Float = 0

  static func clamped(_ progress: Double) -> Double {
    min(max(progress, 0), 1)
  }

  static func isClosed(_ progress: Double) -> Bool {
    clamped(progress) <= endpointTolerance
  }

  static func isOpen(_ progress: Double) -> Bool {
    clamped(progress) >= 1 - endpointTolerance
  }

  static func curlRadius(for extent: CGRect) -> Float {
    Float(max(1, min(extent.width, extent.height) * curlRadiusRatio))
  }

  /// The resting card shadow belongs to the board. Once the cover starts
  /// bending, Core Image's own lighting describes the sheet instead. A short
  /// smooth handoff prevents both renderers from outlining the same rectangle.
  static func restingShadowVisibility(_ progress: Double) -> Double {
    let handoff = min(
      clamped(progress) / shadowHandoffProgress,
      1
    )
    let eased = handoff * handoff * (3 - 2 * handoff)
    return 1 - eased
  }
}

/// Gives the curling cover room to travel while the notebook keeps owning its
/// canonical sheet-sized frame. The opening side reserves one whole cover;
/// the smaller margins carry the filter's bend without turning
/// those pixels into workspace geometry or a new hit target.
struct CoverCurlLayout: Equatable {
  static let openingTravelRatio = 1.0
  static let shadowMarginRatio = 0.04

  let sheetSize: CGSize
  let shadowMargin: CGFloat

  init(sheetSize: CGSize) {
    precondition(sheetSize.width > 0 && sheetSize.height > 0)
    self.sheetSize = sheetSize
    shadowMargin = min(sheetSize.width, sheetSize.height) * Self.shadowMarginRatio
  }

  var sheetFrame: CGRect {
    CGRect(
      x: sheetSize.width * Self.openingTravelRatio + shadowMargin,
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

/// Keeps one frozen cover for one physical curl. Content that arrives while
/// the sheet is moving waits for an endpoint instead of replacing pixels in
/// the person's hand halfway through the gesture.
struct CoverSnapshotLifecycle {
  private(set) var progress = 0.0
  private(set) var revision: CoverRenderingRevision?
  private(set) var capturedCover: CGImage?

  private var ownerID: UUID?
  private var capturedRevision: CoverRenderingRevision?
  private var previousProgress = 0.0

  mutating func update(
    ownerID: UUID,
    progress: Double,
    revision: CoverRenderingRevision
  ) {
    let resolvedProgress = CoverOpeningPhysics.clamped(progress)
    let ownerChanged = self.ownerID != ownerID
    if ownerChanged {
      self.ownerID = ownerID
      clearCapture()
      previousProgress = resolvedProgress
    }

    self.revision = revision
    self.progress = resolvedProgress
    if ownerChanged
      || (CoverOpeningPhysics.isClosed(previousProgress)
        && !CoverOpeningPhysics.isClosed(resolvedProgress))
    {
      clearCapture()
    }
    previousProgress = resolvedProgress
  }

  mutating func settleAtClosedEndpoint() {
    clearCapture()
  }

  mutating func settleAtOpenEndpoint() {
    guard capturedRevision != revision else { return }
    clearCapture()
  }

  mutating func storeCapturedCover(_ image: CGImage?) {
    capturedCover = image
    capturedRevision = image == nil ? nil : revision
  }

  private mutating func clearCapture() {
    capturedCover = nil
    capturedRevision = nil
  }
}

#if os(iOS)
  private struct PlatformCoverOpeningSurface: UIViewControllerRepresentable {
    let ownerID: UUID
    let progress: Double
    let revision: CoverRenderingRevision
    let backsideColor: CoverBacksideColor
    let cornerRadius: CGFloat
    let cover: AnyView

    func makeUIViewController(context: Context) -> IPadCoverOpeningController {
      IPadCoverOpeningController()
    }

    func updateUIViewController(
      _ controller: IPadCoverOpeningController,
      context: Context
    ) {
      controller.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        cover: cover
      )
    }
  }

  @MainActor
  private final class IPadCoverOpeningController: UIViewController {
    private let coverHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let curlView = CoverCurlMetalView(frame: .zero)

    private var lifecycle = CoverSnapshotLifecycle()
    private var backsideColor = CoverBacksideColor.notebook
    private var cornerRadius: CGFloat = 0

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .clear
      view.isOpaque = false
      view.clipsToBounds = false

      addChild(coverHost)
      coverHost.view.backgroundColor = .clear
      coverHost.view.isOpaque = false
      view.addSubview(coverHost.view)
      coverHost.didMove(toParent: self)

      curlView.isHidden = true
      view.addSubview(curlView)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      renderCurrentState()
    }

    func update(
      ownerID: UUID,
      progress: Double,
      revision: CoverRenderingRevision,
      backsideColor: CoverBacksideColor,
      cornerRadius: CGFloat,
      cover: AnyView
    ) {
      lifecycle.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision
      )
      coverHost.rootView = cover
      self.backsideColor = backsideColor
      self.cornerRadius = cornerRadius

      guard isViewLoaded else { return }
      view.setNeedsLayout()
      renderCurrentState()
    }

    private func renderCurrentState() {
      guard let curlLayout = layoutSurfaces() else { return }
      if CoverOpeningPhysics.isClosed(lifecycle.progress) {
        lifecycle.settleAtClosedEndpoint()
        resetCoverHostGeometry()
        coverHost.view.isHidden = false
        coverHost.view.alpha = 1
        coverHost.view.isUserInteractionEnabled = true
        curlView.isHidden = true
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        lifecycle.settleAtOpenEndpoint()
        resetCoverHostGeometry()
        // Keep the live cover in the render tree while the page is open. It is
        // visually absent, but Metal/WebKit can still produce a current frame
        // if the next pinch starts by closing the sheet.
        coverHost.view.isHidden = false
        coverHost.view.alpha = CoverOpeningPhysics.warmCoverOpacity
        coverHost.view.isUserInteractionEnabled = false
        curlView.isHidden = true
        return
      }

      if lifecycle.capturedCover == nil {
        lifecycle.storeCapturedCover(captureCover())
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showLiveCoverUntilSnapshotIsReady()
        return
      }

      coverHost.view.isHidden = true
      coverHost.view.isUserInteractionEnabled = false
      curlView.isHidden = false
      curlView.update(
        cover: capturedCover,
        progress: lifecycle.progress,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        layout: curlLayout
      )
    }

    private func layoutSurfaces() -> CoverCurlLayout? {
      guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
      if coverHost.view.frame != view.bounds {
        coverHost.view.frame = view.bounds
      }
      let layout = CoverCurlLayout(sheetSize: view.bounds.size)
      if curlView.frame != layout.canvasFrameAroundSheet {
        curlView.frame = layout.canvasFrameAroundSheet
      }
      return layout
    }

    private func captureCover() -> CGImage? {
      resetCoverHostGeometry()
      let wasHidden = coverHost.view.isHidden
      let previousAlpha = coverHost.view.alpha
      coverHost.view.isHidden = false
      coverHost.view.alpha = 1
      coverHost.view.frame = view.bounds
      coverHost.view.setNeedsLayout()
      coverHost.view.layoutIfNeeded()

      let format = UIGraphicsImageRendererFormat.preferred()
      format.opaque = false
      format.scale =
        view.window?.screen.scale
        ?? max(view.traitCollection.displayScale, 1)
      let renderer = UIGraphicsImageRenderer(bounds: coverHost.view.bounds, format: format)
      let image = renderer.image { _ in
        coverHost.view.drawHierarchy(
          in: coverHost.view.bounds,
          afterScreenUpdates: false
        )
      }
      coverHost.view.alpha = previousAlpha
      coverHost.view.isHidden = wasHidden
      return image.cgImage
    }

    private func resetCoverHostGeometry() {
      coverHost.view.layer.transform = CATransform3DIdentity
      coverHost.view.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      coverHost.view.layer.position = CGPoint(
        x: view.bounds.midX,
        y: view.bounds.midY
      )
    }

    private func showLiveCoverUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverHost.view.isHidden = false
      coverHost.view.alpha = 1
      coverHost.view.isUserInteractionEnabled = false
      curlView.isHidden = true
    }
  }
#elseif os(macOS)
  private struct PlatformCoverOpeningSurface: NSViewRepresentable {
    let ownerID: UUID
    let progress: Double
    let revision: CoverRenderingRevision
    let backsideColor: CoverBacksideColor
    let cornerRadius: CGFloat
    let cover: AnyView

    func makeNSView(context: Context) -> MacCoverOpeningView {
      MacCoverOpeningView(frame: .zero)
    }

    func updateNSView(_ view: MacCoverOpeningView, context: Context) {
      view.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        cover: cover
      )
    }
  }

  @MainActor
  private final class MacCoverOpeningView: NSView {
    private let coverHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let curlView = CoverCurlMetalView(frame: .zero)

    private var lifecycle = CoverSnapshotLifecycle()
    private var backsideColor = CoverBacksideColor.notebook
    private var cornerRadius: CGFloat = 0

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.masksToBounds = false
      coverHost.wantsLayer = true
      coverHost.layer?.backgroundColor = NSColor.clear.cgColor
      addSubview(coverHost)
      curlView.isHidden = true
      addSubview(curlView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func layout() {
      super.layout()
      renderCurrentState()
    }

    func update(
      ownerID: UUID,
      progress: Double,
      revision: CoverRenderingRevision,
      backsideColor: CoverBacksideColor,
      cornerRadius: CGFloat,
      cover: AnyView
    ) {
      lifecycle.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision
      )
      coverHost.rootView = cover
      self.backsideColor = backsideColor
      self.cornerRadius = cornerRadius

      needsLayout = true
      renderCurrentState()
    }

    private func renderCurrentState() {
      guard let curlLayout = layoutSurfaces() else { return }
      if CoverOpeningPhysics.isClosed(lifecycle.progress) {
        lifecycle.settleAtClosedEndpoint()
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = 1
        curlView.isHidden = true
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        lifecycle.settleAtOpenEndpoint()
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = CoverOpeningPhysics.warmCoverOpacity
        curlView.isHidden = true
        return
      }

      if lifecycle.capturedCover == nil {
        lifecycle.storeCapturedCover(captureCover())
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showLiveCoverUntilSnapshotIsReady()
        return
      }

      coverHost.isHidden = true
      curlView.isHidden = false
      curlView.update(
        cover: capturedCover,
        progress: lifecycle.progress,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        layout: curlLayout
      )
    }

    private func layoutSurfaces() -> CoverCurlLayout? {
      guard bounds.width > 0, bounds.height > 0 else { return nil }
      if coverHost.frame != bounds {
        coverHost.frame = bounds
      }
      let layout = CoverCurlLayout(sheetSize: bounds.size)
      if curlView.frame != layout.canvasFrameAroundSheet {
        curlView.frame = layout.canvasFrameAroundSheet
      }
      return layout
    }

    private func captureCover() -> CGImage? {
      resetCoverHostGeometry()
      let wasHidden = coverHost.isHidden
      let previousAlpha = coverHost.alphaValue
      coverHost.isHidden = false
      coverHost.alphaValue = 1
      coverHost.frame = bounds
      coverHost.layoutSubtreeIfNeeded()
      guard
        let representation = coverHost.bitmapImageRepForCachingDisplay(
          in: coverHost.bounds
        )
      else {
        coverHost.alphaValue = previousAlpha
        coverHost.isHidden = wasHidden
        return nil
      }
      coverHost.cacheDisplay(in: coverHost.bounds, to: representation)
      coverHost.alphaValue = previousAlpha
      coverHost.isHidden = wasHidden
      return representation.cgImage
    }

    private func resetCoverHostGeometry() {
      coverHost.layer?.transform = CATransform3DIdentity
      coverHost.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      coverHost.layer?.position = CGPoint(
        x: bounds.midX,
        y: bounds.midY
      )
    }

    private func showLiveCoverUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverHost.isHidden = false
      coverHost.alphaValue = 1
      curlView.isHidden = true
    }
  }
#endif

/// GPU executor for the physical sheet. Core Image owns curl geometry and
/// backside illumination; this view supplies the frozen cover pixels, clears
/// every drawable, and presents the camera-owned progress value.
@MainActor
private final class CoverCurlMetalView: MTKView, MTKViewDelegate {
  private let commandQueue: (any MTLCommandQueue)?
  private let imageContext: CIContext?
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private let inFlightSemaphore = DispatchSemaphore(value: 2)

  private var coverImage: CIImage?
  private var progress = 0.0
  private var backsideColor = CoverBacksideColor.notebook
  private var cornerRadius: CGFloat = 0
  private var curlLayout: CoverCurlLayout?

  override init(frame frameRect: CGRect, device: (any MTLDevice)? = nil) {
    let metalDevice = device ?? MTLCreateSystemDefaultDevice()
    commandQueue = metalDevice?.makeCommandQueue()
    imageContext = metalDevice.map {
      CIContext(
        mtlDevice: $0,
        options: [
          .cacheIntermediates: false,
          .workingColorSpace: NSNull(),
        ]
      )
    }
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

  func update(
    cover: CGImage,
    progress: Double,
    backsideColor: CoverBacksideColor,
    cornerRadius: CGFloat,
    layout: CoverCurlLayout
  ) {
    coverImage = CIImage(cgImage: cover)
    self.progress = CoverOpeningPhysics.clamped(progress)
    self.backsideColor = backsideColor
    self.cornerRadius = cornerRadius
    curlLayout = layout
    setNeedsDisplay(bounds)
  }

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    setNeedsDisplay(bounds)
  }

  func draw(in view: MTKView) {
    guard inFlightSemaphore.wait(timeout: .now()) == .success else {
      setNeedsDisplay(bounds)
      return
    }
    var mustSignal = true
    defer {
      if mustSignal { inFlightSemaphore.signal() }
    }

    guard drawableSize.width > 0,
      drawableSize.height > 0,
      let curlLayout,
      let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let drawable = currentDrawable,
      let imageContext
    else { return }

    let canvasExtent = CGRect(origin: .zero, size: drawableSize)
    let sheetExtent = curlLayout.sheetExtent(inDrawableSize: drawableSize)
    guard let input = placedCoverImage(in: sheetExtent) else { return }
    let filter = CIFilter.pageCurlWithShadowTransition()
    filter.inputImage = input
    filter.targetImage = CIImage(color: .clear).cropped(to: sheetExtent)
    filter.backsideImage = roundedBacksideImage(extent: sheetExtent)
    filter.extent = sheetExtent
    filter.time = Float(progress)
    filter.angle = .pi
    filter.radius = CoverOpeningPhysics.curlRadius(for: sheetExtent)
    // CIPageCurlWithShadowTransition's cast shadow includes its opaque output
    // extent. The fold's own lighting is the visual owner while the sheet moves,
    // so these values keep the surrounding Metal canvas transparent.
    filter.shadowSize = CoverOpeningPhysics.systemShadowSize
    filter.shadowAmount = CoverOpeningPhysics.systemShadowAmount
    filter.shadowExtent = canvasExtent

    guard let output = filter.outputImage?.cropped(to: canvasExtent) else {
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
    commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
      inFlightSemaphore.signal()
    }
    mustSignal = false
    commandBuffer.present(drawable)
    commandBuffer.commit()
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

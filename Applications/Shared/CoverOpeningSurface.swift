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
  static let shadowSize: Float = 0.32
  static let shadowAmount: Float = 0.46

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
      coverHost.view.frame = view.bounds
      curlView.frame = view.bounds
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
      guard !view.bounds.isEmpty else { return }
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
        cornerRadius: cornerRadius
      )
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
      coverHost.frame = bounds
      curlView.frame = bounds
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
      guard !bounds.isEmpty else { return }
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
        cornerRadius: cornerRadius
      )
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

/// GPU executor for the physical sheet. Core Image owns curl geometry,
/// backside illumination, and cast shadow; this view only supplies the frozen
/// cover pixels and the camera-owned progress value.
@MainActor
private final class CoverCurlMetalView: MTKView, MTKViewDelegate {
  private let commandQueue: (any MTLCommandQueue)?
  private let imageContext: CIContext?
  private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private let inFlightSemaphore = DispatchSemaphore(value: 3)

  private var coverImage: CIImage?
  private var progress = 0.0
  private var backsideColor = CoverBacksideColor.notebook
  private var cornerRadius: CGFloat = 0

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
    #elseif os(macOS)
      wantsLayer = true
      layer?.isOpaque = false
      layer?.backgroundColor = NSColor.clear.cgColor
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
    cornerRadius: CGFloat
  ) {
    coverImage = CIImage(cgImage: cover)
    self.progress = CoverOpeningPhysics.clamped(progress)
    self.backsideColor = backsideColor
    self.cornerRadius = cornerRadius
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
      let input = fittedCoverImage(),
      let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let drawable = currentDrawable,
      let imageContext
    else { return }

    let extent = CGRect(origin: .zero, size: drawableSize)
    let filter = CIFilter.pageCurlWithShadowTransition()
    filter.inputImage = input
    filter.targetImage = CIImage(color: .clear).cropped(to: extent)
    filter.backsideImage = roundedBacksideImage(extent: extent)
    filter.extent = extent
    filter.time = Float(progress)
    filter.angle = .pi
    filter.radius = CoverOpeningPhysics.curlRadius(for: extent)
    filter.shadowSize = CoverOpeningPhysics.shadowSize
    filter.shadowAmount = CoverOpeningPhysics.shadowAmount
    filter.shadowExtent = extent.insetBy(
      dx: -extent.width * 0.12,
      dy: -extent.height * 0.08
    )

    guard let output = filter.outputImage?.cropped(to: extent) else { return }
    imageContext.render(
      output,
      to: drawable.texture,
      commandBuffer: commandBuffer,
      bounds: extent,
      colorSpace: outputColorSpace
    )
    commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
      inFlightSemaphore.signal()
    }
    mustSignal = false
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func fittedCoverImage() -> CIImage? {
    guard let coverImage else { return nil }
    let target = CGSize(
      width: max(drawableSize.width, 1),
      height: max(drawableSize.height, 1)
    )
    let source = coverImage.extent.size
    guard source.width > 0, source.height > 0 else { return nil }
    let transform = CGAffineTransform(
      scaleX: target.width / source.width,
      y: target.height / source.height
    )
    return coverImage.transformed(by: transform).cropped(
      to: CGRect(origin: .zero, size: target)
    )
  }

  private func roundedBacksideImage(extent: CGRect) -> CIImage {
    let color = CIImage(color: backsideColor.ciColor).cropped(to: extent)
    let radius = cornerRadius * extent.width / max(bounds.width, 1)
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
}

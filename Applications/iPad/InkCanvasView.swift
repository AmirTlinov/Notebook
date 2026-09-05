import MetalKit
import NotebookCore
import PencilKit
import UIKit

/// One mutable geometry record follows a pen stroke from Pencil-down to disk.
@MainActor
final class ActiveInkStroke {
  let style: PenStyle
  private(set) var measuredPoints: [PKStrokePoint] = []
  private(set) var predictedPoints: [PKStrokePoint] = []
  private(set) var revision: UInt64 = 0

  init(style: PenStyle) {
    self.style = style
  }

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    measuredPoints.replaceSubrange(start..., with: points)
    revision &+= 1
  }

  func replacePredictions(with points: [PKStrokePoint]) {
    predictedPoints = points
    revision &+= 1
  }
}

/// One mutable eraser path is composited by Metal while Pencil is moving.
@MainActor
final class ActiveEraserStroke {
  private(set) var measuredPoints: [PKStrokePoint] = []
  private(set) var revision: UInt64 = 0

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    measuredPoints.replaceSubrange(start..., with: points)
    revision &+= 1
  }
}

/// The one renderer that turns a mounted notebook surface into pixels on iPad.
///
/// A page later persists as PencilKit; the spatial scene persists raw journal
/// samples. Metal owns every live pixel and replays each stable format without
/// replacing the geometry that was shown under Pencil.
@MainActor
final class InkCanvasView: MTKView, MTKViewDelegate {
  private enum RenderOperation: Equatable {
    case ink
    case erase
  }

  private typealias Vertex = SpatialInkGeometry.Vertex

  private struct CommittedBatch {
    let operation: RenderOperation
    var vertices: [Vertex]
    var buffer: (any MTLBuffer)?
  }

  private struct StableRasterKey: Equatable {
    let drawingRevision: UInt64
    let size: CGSize
  }

  private struct StableRaster: @unchecked Sendable {
    let image: CGImage
  }

  private static let framesInFlight = 3
  nonisolated private static let stableRasterScale: CGFloat = 2

  private let commandQueue: (any MTLCommandQueue)?
  private let stableInkPipelineState: (any MTLRenderPipelineState)?
  private let inkPipelineState: (any MTLRenderPipelineState)?
  private let eraserPipelineState: (any MTLRenderPipelineState)?
  private let textureLoader: MTKTextureLoader?
  private let inFlightSemaphore = DispatchSemaphore(
    value: InkCanvasView.framesInFlight
  )

  private var committedBatches: [CommittedBatch] = []
  private var stableDrawing: PKDrawing?
  private var stableDrawingRevision: UInt64 = 0
  private var stableTexture: (any MTLTexture)?
  private var installedStableRasterKey: StableRasterKey?
  private var pendingStableRasterKey: StableRasterKey?
  private var stableRasterTask: Task<Void, Never>?

  private var activeInkStroke: ActiveInkStroke?
  private var activeEraserStroke: ActiveEraserStroke?
  private var builtActiveIdentity: ObjectIdentifier?
  private var builtActiveRevision: UInt64?
  private var activeVertices: [Vertex] = []
  private var activeBuffers = Array<(any MTLBuffer)?>(
    repeating: nil,
    count: InkCanvasView.framesInFlight
  )
  private var activeBufferCapacities = Array(
    repeating: 0,
    count: InkCanvasView.framesInFlight
  )
  private var frameSlot = 0
  private var hasPresentedFrame = false
  private var stableContentRevision: UInt64 = 0
  private var presentedStableContentRevision: UInt64?

  var onRenderReadinessChange: ((Bool) -> Void)? {
    didSet {
      onRenderReadinessChange?(
        presentedStableContentRevision == stableContentRevision
      )
    }
  }

  var committedVertexCount: Int {
    committedBatches.reduce(0) { $0 + $1.vertices.count }
  }

  var committedEraserVertexCount: Int {
    committedBatches.reduce(0) { count, batch in
      count + (batch.operation == .erase ? batch.vertices.count : 0)
    }
  }

  init(frame: CGRect) {
    let device = MTLCreateSystemDefaultDevice()
    commandQueue = device?.makeCommandQueue()
    textureLoader = device.map(MTKTextureLoader.init(device:))

    if let device,
      let library = try? device.makeDefaultLibrary(bundle: .main),
      let vertexFunction = library.makeFunction(name: "paperInkVertex"),
      let fragmentFunction = library.makeFunction(name: "paperInkFragment"),
      let stableVertexFunction = library.makeFunction(name: "stableInkVertex"),
      let stableFragmentFunction = library.makeFunction(
        name: "stableInkFragment"
      )
    {
      let sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
      let stableDescriptor = MTLRenderPipelineDescriptor()
      stableDescriptor.label = "Stable Notebook Ink"
      stableDescriptor.vertexFunction = stableVertexFunction
      stableDescriptor.fragmentFunction = stableFragmentFunction
      stableDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      stableDescriptor.rasterSampleCount = sampleCount

      let stableAttachment = stableDescriptor.colorAttachments[0]!
      stableAttachment.isBlendingEnabled = true
      stableAttachment.rgbBlendOperation = .add
      stableAttachment.alphaBlendOperation = .add
      stableAttachment.sourceRGBBlendFactor = .one
      stableAttachment.sourceAlphaBlendFactor = .one
      stableAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      stableAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      stableInkPipelineState = try? device.makeRenderPipelineState(
        descriptor: stableDescriptor
      )

      let inkDescriptor = MTLRenderPipelineDescriptor()
      inkDescriptor.label = "Notebook Ink"
      inkDescriptor.vertexFunction = vertexFunction
      inkDescriptor.fragmentFunction = fragmentFunction
      inkDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      inkDescriptor.rasterSampleCount = sampleCount

      let inkAttachment = inkDescriptor.colorAttachments[0]!
      inkAttachment.isBlendingEnabled = true
      inkAttachment.rgbBlendOperation = .add
      inkAttachment.alphaBlendOperation = .add
      inkAttachment.sourceRGBBlendFactor = .one
      inkAttachment.sourceAlphaBlendFactor = .one
      inkAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      inkAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      inkPipelineState = try? device.makeRenderPipelineState(
        descriptor: inkDescriptor
      )

      let eraserDescriptor = MTLRenderPipelineDescriptor()
      eraserDescriptor.label = "Notebook Eraser"
      eraserDescriptor.vertexFunction = vertexFunction
      eraserDescriptor.fragmentFunction = fragmentFunction
      eraserDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      eraserDescriptor.rasterSampleCount = sampleCount

      let eraserAttachment = eraserDescriptor.colorAttachments[0]!
      eraserAttachment.isBlendingEnabled = true
      eraserAttachment.rgbBlendOperation = .add
      eraserAttachment.alphaBlendOperation = .add
      eraserAttachment.sourceRGBBlendFactor = .zero
      eraserAttachment.sourceAlphaBlendFactor = .zero
      eraserAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      eraserAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      eraserPipelineState = try? device.makeRenderPipelineState(
        descriptor: eraserDescriptor
      )
    } else {
      stableInkPipelineState = nil
      inkPipelineState = nil
      eraserPipelineState = nil
    }

    super.init(frame: frame, device: device)

    colorPixelFormat = .bgra8Unorm
    sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    framebufferOnly = true
    enableSetNeedsDisplay = false
    isPaused = false
    preferredFramesPerSecond = 120
    autoResizeDrawable = true
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    layer.isOpaque = false
    layer.opacity = 0
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.presentsWithTransaction = false
      metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      metalLayer.maximumDrawableCount = Self.framesInFlight
    }
    delegate = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let screen = window?.windowScene?.screen {
      preferredFramesPerSecond = screen.maximumFramesPerSecond
    }
    if window != nil {
      isPaused = false
      scheduleStableRasterIfNeeded()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scheduleStableRasterIfNeeded()
  }

  /// Replaces the page atomically. This is used for load, undo, and sync.
  func apply(_ drawing: PKDrawing) {
    beginStableContentUpdate()
    stableRasterTask?.cancel()
    stableRasterTask = nil
    stableDrawingRevision &+= 1
    stableDrawing = drawing
    stableTexture = nil
    installedStableRasterKey = nil
    pendingStableRasterKey = nil
    committedBatches.removeAll(keepingCapacity: true)
    discardActiveAction()
    scheduleStableRasterIfNeeded()
  }

  /// Replaces finished live batches only after PencilKit has produced the
  /// exact durable pixels for the same drawing. A newer active gesture keeps
  /// the existing base and batches until its own durable drawing settles.
  func settle(_ drawing: PKDrawing) {
    beginStableContentUpdate()
    stableRasterTask?.cancel()
    stableRasterTask = nil
    stableDrawingRevision &+= 1
    stableDrawing = drawing
    pendingStableRasterKey = nil
    scheduleStableRasterIfNeeded()
  }

  /// Rebuilds one spatial surface from its ordered raw journal actions.
  func applySpatial(_ layers: [SpatialInkRenderLayer]) {
    beginStableContentUpdate()
    stableRasterTask?.cancel()
    stableRasterTask = nil
    stableDrawingRevision &+= 1
    stableDrawing = nil
    stableTexture = nil
    installedStableRasterKey = nil
    pendingStableRasterKey = nil
    committedBatches.removeAll(keepingCapacity: true)

    for layer in layers {
      switch layer {
      case .ink(let points, let color):
        var vertices: [Vertex] = []
        SpatialInkGeometry.appendStrokeVertices(
          points: points,
          color: SIMD4(
            Float(color.red),
            Float(color.green),
            Float(color.blue),
            1
          ),
          to: &vertices
        )
        appendCommitted(vertices, operation: .ink)
      case .erase(let points):
        var vertices: [Vertex] = []
        SpatialInkGeometry.appendStrokeVertices(
          points: points,
          color: SIMD4(1, 1, 1, 1),
          to: &vertices
        )
        appendCommitted(vertices, operation: .erase)
      }
    }
    discardActiveAction()
    requestFrame()
  }

  /// Publishes the newest Pencil samples. Rendering happens on the display
  /// clock, never inside the touch callback.
  func displayActiveStroke(_ stroke: ActiveInkStroke) {
    if activeInkStroke !== stroke {
      cancelPendingStableRaster()
      activeInkStroke = stroke
      activeEraserStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Shows a destination-out brush over the stable page. PencilKit does not
  /// produce any visible intermediate drawings while the gesture is active.
  func displayActiveEraser(_ stroke: ActiveEraserStroke) {
    if activeEraserStroke !== stroke {
      cancelPendingStableRaster()
      activeEraserStroke = stroke
      activeInkStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Moves the exact active mesh into the page. No second renderer and no
  /// visual replacement are involved.
  func commitActiveStroke() {
    if let activeInkStroke,
      !activeInkStroke.measuredPoints.isEmpty
    {
      let components = activeInkStroke.style.color.components
      var vertices: [Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(
        points: activeInkStroke.measuredPoints,
        color: SIMD4(
          Float(components.red),
          Float(components.green),
          Float(components.blue),
          1
        ),
        to: &vertices
      )
      appendCommitted(vertices, operation: .ink)
    }
    discardActiveAction()
    requestFrame()
  }

  /// Keeps the exact Metal eraser gesture in the action order. The PencilKit
  /// result is persistence for Mac and reload, not a second live renderer.
  func commitActiveEraser() {
    if let activeEraserStroke,
      !activeEraserStroke.measuredPoints.isEmpty
    {
      var vertices: [Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(
        points: activeEraserStroke.measuredPoints,
        color: SIMD4(1, 1, 1, 1),
        to: &vertices
      )
      appendCommitted(vertices, operation: .erase)
    }
    discardActiveAction()
    requestFrame()
  }

  /// Freezes a finished board or cover gesture into this same Metal surface.
  /// The journal replay may arrive on a later frame; a following Pencil-down
  /// can therefore clear only its own live tip, never the preceding stroke.
  func commitActiveSpatialAction() {
    if let activeInkStroke, !activeInkStroke.measuredPoints.isEmpty {
      let components = activeInkStroke.style.color.components
      var vertices: [Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(
        points: activeInkStroke.measuredPoints,
        color: SIMD4(
          Float(components.red),
          Float(components.green),
          Float(components.blue),
          1
        ),
        to: &vertices
      )
      appendCommitted(vertices, operation: .ink)
    } else if let activeEraserStroke,
      !activeEraserStroke.measuredPoints.isEmpty
    {
      var vertices: [Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(
        points: activeEraserStroke.measuredPoints,
        color: SIMD4(1, 1, 1, 1),
        to: &vertices
      )
      appendCommitted(vertices, operation: .erase)
    }
    discardActiveAction()
    requestFrame()
  }

  func clearActiveAction() {
    guard activeInkStroke != nil || activeEraserStroke != nil else { return }
    discardActiveAction()
    requestFrame()
  }

  func mtkView(
    _ view: MTKView,
    drawableSizeWillChange size: CGSize
  ) {
    scheduleStableRasterIfNeeded()
    requestFrame()
  }

  func draw(in view: MTKView) {
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal {
        inFlightSemaphore.signal()
      }
    }

    guard let commandQueue,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let descriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable
    else { return }

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = clearColor
    guard let encoder = commandBuffer.makeRenderCommandEncoder(
      descriptor: descriptor
    ) else { return }

    for index in committedBatches.indices
      where committedBatches[index].buffer == nil
    {
      committedBatches[index].buffer = makeBuffer(
        for: committedBatches[index].vertices
      )
    }
    let active = prepareActiveBuffer(in: frameSlot)

    if let stableTexture, let stableInkPipelineState {
      encoder.label = "Stable Notebook Ink"
      encoder.setRenderPipelineState(stableInkPipelineState)
      encoder.setFragmentTexture(stableTexture, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6
      )
    }

    if inkPipelineState != nil, eraserPipelineState != nil {
      encoder.label = "Notebook Ink"
      var viewportSize = SIMD2<Float>(
        Float(max(bounds.width, 1)),
        Float(max(bounds.height, 1))
      )
      encoder.setVertexBytes(
        &viewportSize,
        length: MemoryLayout<SIMD2<Float>>.stride,
        index: 1
      )
      for batch in committedBatches {
        draw(
          buffer: batch.buffer,
          vertexCount: batch.vertices.count,
          operation: batch.operation,
          with: encoder
        )
      }
      if let active {
        draw(
          buffer: active.buffer,
          vertexCount: activeVertices.count,
          operation: active.operation,
          with: encoder
        )
      }
    }
    encoder.endEncoding()

    commandBuffer.present(drawable)
    let presentedRevision: UInt64? =
      activeInkStroke == nil
        && activeEraserStroke == nil
        && stableRasterIsReady
      ? stableContentRevision : nil
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore] _ in
      inFlightSemaphore.signal()
      guard let presentedRevision else { return }
      Task { @MainActor [weak self] in
        guard let self,
          stableContentRevision == presentedRevision,
          presentedStableContentRevision != presentedRevision
        else { return }
        presentedStableContentRevision = presentedRevision
        onRenderReadinessChange?(true)
      }
    }
    commandBuffer.commit()
    mustSignal = false
    frameSlot = (frameSlot + 1) % Self.framesInFlight

    if !hasPresentedFrame {
      // The first drawable may contain Metal's diagnostic magenta. Reveal the
      // layer only after its transparent clear has reached the GPU once.
      commandBuffer.waitUntilCompleted()
      hasPresentedFrame = true
      layer.opacity = 1
    }

    if activeInkStroke == nil, activeEraserStroke == nil { isPaused = true }
  }

  private func beginStableContentUpdate() {
    stableContentRevision &+= 1
    onRenderReadinessChange?(false)
  }

  private var stableRasterIsReady: Bool {
    guard stableDrawing != nil else { return true }
    guard let key = desiredStableRasterKey else { return false }
    return installedStableRasterKey == key
  }

  private var desiredStableRasterKey: StableRasterKey? {
    guard stableDrawing != nil,
      bounds.width > 0,
      bounds.height > 0
    else { return nil }
    return StableRasterKey(
      drawingRevision: stableDrawingRevision,
      size: bounds.size
    )
  }

  private func cancelPendingStableRaster() {
    stableRasterTask?.cancel()
    stableRasterTask = nil
    pendingStableRasterKey = nil
  }

  private func scheduleStableRasterIfNeeded() {
    guard activeInkStroke == nil,
      activeEraserStroke == nil,
      let drawing = stableDrawing,
      let key = desiredStableRasterKey,
      installedStableRasterKey != key,
      pendingStableRasterKey != key
    else { return }

    stableRasterTask?.cancel()
    pendingStableRasterKey = key

    if drawing.strokes.isEmpty {
      installStableRaster(nil, for: key)
      return
    }

    let rasterBounds = CGRect(origin: .zero, size: key.size)
    stableRasterTask = Task { [weak self] in
      let raster = await Task.detached(priority: .userInitiated) {
        Self.makeStableRaster(
          from: drawing,
          bounds: rasterBounds,
          scale: Self.stableRasterScale
        )
      }.value
      guard let self else { return }
      guard acceptsStableRaster(for: key),
        let raster,
        let texture = await makeTexture(from: raster),
        acceptsStableRaster(for: key)
      else {
        if pendingStableRasterKey == key {
          stableRasterTask = nil
          pendingStableRasterKey = nil
        }
        return
      }
      installStableRaster(texture, for: key)
    }
  }

  private func acceptsStableRaster(for key: StableRasterKey) -> Bool {
    !Task.isCancelled
      && pendingStableRasterKey == key
      && desiredStableRasterKey == key
      && activeInkStroke == nil
      && activeEraserStroke == nil
  }

  private func makeTexture(
    from raster: StableRaster
  ) async -> (any MTLTexture)? {
    guard let textureLoader else { return nil }
    return try? await textureLoader.newTexture(
      cgImage: raster.image,
      options: [
        .SRGB: true,
        .origin: MTKTextureLoader.Origin.topLeft.rawValue,
      ]
    )
  }

  private func installStableRaster(
    _ texture: (any MTLTexture)?,
    for key: StableRasterKey
  ) {
    guard desiredStableRasterKey == key,
      activeInkStroke == nil,
      activeEraserStroke == nil
    else { return }
    stableTexture = texture
    installedStableRasterKey = key
    pendingStableRasterKey = nil
    stableRasterTask = nil
    committedBatches.removeAll(keepingCapacity: true)
    requestFrame()
  }

  nonisolated private static func makeStableRaster(
    from drawing: PKDrawing,
    bounds: CGRect,
    scale: CGFloat
  ) -> StableRaster? {
    autoreleasepool {
      guard let image = drawing.image(from: bounds, scale: scale).cgImage else {
        return nil
      }
      return StableRaster(image: image)
    }
  }

  private func requestFrame() {
    isPaused = false
  }

  private func discardActiveAction() {
    activeInkStroke = nil
    activeEraserStroke = nil
    builtActiveIdentity = nil
    builtActiveRevision = nil
    activeVertices.removeAll(keepingCapacity: true)
  }

  private func prepareActiveBuffer(
    in slot: Int
  ) -> (buffer: any MTLBuffer, operation: RenderOperation)? {
    let identity: ObjectIdentifier
    let revision: UInt64
    let measured: [PKStrokePoint]
    let predicted: [PKStrokePoint]
    let color: SIMD4<Float>
    let operation: RenderOperation

    if let activeInkStroke {
      identity = ObjectIdentifier(activeInkStroke)
      revision = activeInkStroke.revision
      measured = activeInkStroke.measuredPoints
      predicted = activeInkStroke.predictedPoints
      let components = activeInkStroke.style.color.components
      color = SIMD4(
        Float(components.red),
        Float(components.green),
        Float(components.blue),
        1
      )
      operation = .ink
    } else if let activeEraserStroke {
      identity = ObjectIdentifier(activeEraserStroke)
      revision = activeEraserStroke.revision
      measured = activeEraserStroke.measuredPoints
      predicted = []
      color = SIMD4(1, 1, 1, 1)
      operation = .erase
    } else {
      activeVertices.removeAll(keepingCapacity: true)
      builtActiveIdentity = nil
      builtActiveRevision = nil
      return nil
    }

    if builtActiveIdentity != identity || builtActiveRevision != revision {
      activeVertices = makeVertices(
        measured: measured,
        predicted: predicted,
        color: color
      )
      builtActiveIdentity = identity
      builtActiveRevision = revision
    }
    guard !activeVertices.isEmpty else { return nil }

    let requiredLength = activeVertices.count * MemoryLayout<Vertex>.stride
    if requiredLength > activeBufferCapacities[slot] {
      activeBufferCapacities[slot] = max(
        4096,
        nextPowerOfTwo(requiredLength)
      )
      activeBuffers[slot] = device?.makeBuffer(
        length: activeBufferCapacities[slot],
        options: .storageModeShared
      )
      activeBuffers[slot]?.label = "Active Pencil Stroke \(slot)"
    }
    guard let buffer = activeBuffers[slot] else {
      return nil
    }
    // Every in-flight frame owns its slot. The CPU never overwrites vertices
    // that a preceding GPU command buffer may still be reading.
    copy(activeVertices, to: buffer)
    return (buffer, operation)
  }

  private func appendCommitted(
    _ vertices: [Vertex],
    operation: RenderOperation
  ) {
    guard !vertices.isEmpty else { return }
    if committedBatches.last?.operation == operation {
      committedBatches[committedBatches.count - 1].vertices.append(
        contentsOf: vertices
      )
      committedBatches[committedBatches.count - 1].buffer = nil
    } else {
      committedBatches.append(
        CommittedBatch(
          operation: operation,
          vertices: vertices,
          buffer: nil
        )
      )
    }
  }

  private func makeBuffer(for vertices: [Vertex]) -> (any MTLBuffer)? {
    guard let device, !vertices.isEmpty else { return nil }
    return vertices.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return nil }
      let buffer = device.makeBuffer(
        bytes: baseAddress,
        length: bytes.count,
        options: .storageModeShared
      )
      buffer?.label = "Committed Notebook Ink"
      return buffer
    }
  }

  private func copy(_ vertices: [Vertex], to buffer: any MTLBuffer) {
    vertices.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else { return }
      buffer.contents().copyMemory(
        from: baseAddress,
        byteCount: source.count
      )
    }
  }

  private func draw(
    buffer: (any MTLBuffer)?,
    vertexCount: Int,
    operation: RenderOperation,
    with encoder: any MTLRenderCommandEncoder
  ) {
    guard let buffer, vertexCount > 0 else { return }
    let pipeline = operation == .ink
      ? inkPipelineState
      : eraserPipelineState
    guard let pipeline else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: vertexCount
    )
  }

  private func makeVertices(
    measured: [PKStrokePoint],
    predicted: [PKStrokePoint],
    color: SIMD4<Float>
  ) -> [Vertex] {
    var points = measured
    points.reserveCapacity(measured.count + predicted.count)
    points.append(contentsOf: predicted)
    var vertices: [Vertex] = []
    vertices.reserveCapacity(points.count * 6)
    SpatialInkGeometry.appendStrokeVertices(points: points, color: color, to: &vertices)
    return vertices
  }

  private func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
  }
}

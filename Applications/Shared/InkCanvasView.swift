import MetalKit
import NotebookCore
import PencilKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One mutable geometry record follows a pen stroke from Pencil-down to disk.
@MainActor
final class ActiveInkStroke {
  let style: PenStyle
  private(set) var measuredPoints: [PKStrokePoint] = []
  private(set) var predictedPoints: [PKStrokePoint] = []
  private(set) var revision: UInt64 = 0
  private var changedFrom = 0

  func consumeChangedStart() -> Int {
    defer { changedFrom = measuredPoints.count }
    return changedFrom
  }

  init(style: PenStyle) {
    self.style = style
  }

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    changedFrom = min(changedFrom, start)
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
  private var changedFrom = 0

  func consumeChangedStart() -> Int {
    defer { changedFrom = measuredPoints.count }
    return changedFrom
  }

  func replaceMeasuredTail(
    from startIndex: Int,
    with points: [PKStrokePoint]
  ) {
    let start = min(max(startIndex, 0), measuredPoints.count)
    changedFrom = min(changedFrom, start)
    measuredPoints.replaceSubrange(start..., with: points)
    revision &+= 1
  }
}

/// The renderer that turns a mounted notebook surface into pixels on both platforms.
///
/// Pages and spatial surfaces persist the measured samples. Shared geometry and
/// Metal shaders own the live line, its settled raster and the agent image.
@MainActor
final class InkCanvasView: MTKView, MTKViewDelegate {
  private enum RenderOperation: Equatable {
    case ink
    case erase
  }

  private typealias Vertex = SpatialInkGeometry.Vertex

  private struct GeometryBuffer {
    let buffer: any MTLBuffer
    let reservation: RasterReservation
  }

  private struct CommittedBatch {
    let mesh: SpatialInkMesh.Batch
    var buffers: [GeometryBuffer?]
    var operation: RenderOperation { mesh.tool == .pen ? .ink : .erase }
    init(_ mesh: SpatialInkMesh.Batch) {
      self.mesh = mesh
      buffers = Array(repeating: nil, count: mesh.chunks.count)
    }
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
  private let resources: SceneRenderResources
  private let inFlightSemaphore = DispatchSemaphore(
    value: InkCanvasView.framesInFlight
  )

  private var spatialCamera: SpatialCamera?
  private var spatialViewport = SpatialPoint(x: 1, y: 1)
  private var committedBatches: [CommittedBatch] = []
  private var spatialActionBase: [CommittedBatch]?
  private var stableDrawing: PageInkDrawing?
  private var drawingIsPreparing = false
  private var stableDrawingRevision: UInt64 = 0
  private var stableTexture: (any MTLTexture)?
  private var installedStableRasterKey: StableRasterKey?
  private var pendingStableRasterKey: StableRasterKey?
  private var stableRasterTask: Task<Void, Never>?

  private var activeInkStroke: ActiveInkStroke?
  private var activeEraserStroke: ActiveEraserStroke?
  private var builtActiveIdentity: ObjectIdentifier?
  private var builtActiveRevision: UInt64?
  private var activeMesh = IncrementalInkMesh()
  private var activeBufferDirtyStarts = Array(repeating: 0, count: InkCanvasView.framesInFlight)
  private var activeBuffers = Array<(any MTLBuffer)?>(
    repeating: nil,
    count: InkCanvasView.framesInFlight
  )
  private var activeBufferReservations = Array<RasterReservation?>(
    repeating: nil, count: InkCanvasView.framesInFlight)
  private var activeBufferCapacities = Array(
    repeating: 0,
    count: InkCanvasView.framesInFlight
  )
  private var frameSlot = 0
  private var hasRevealedFirstFrame = false
  private var stableContentRevision: UInt64 = 0
  private var presentedStableContentRevision: UInt64?
  private(set) var drawableRequestCount = 0
  private(set) var activeUploadedByteCount = 0
  private(set) var visibleCommittedVertexCount = 0
  private(set) var visibleCommittedChunkCount = 0
  private(set) var renderFailure: SceneRenderError?
  var residentCommittedBufferBytes: Int {
    committedBatches.reduce(0) { count, batch in
      count + batch.buffers.reduce(0) { $0 + ($1?.reservation.byteCount ?? 0) }
    }
  }

  var isStableFramePresented: Bool {
    presentedStableContentRevision == stableContentRevision
  }

  var onRenderReadinessChange: ((Bool) -> Void)? {
    didSet {
      onRenderReadinessChange?(isStableFramePresented)
    }
  }

  var committedVertexCount: Int {
    committedBatches.reduce(0) { $0 + $1.mesh.vertices.count }
  }

  var committedEraserVertexCount: Int {
    committedBatches.reduce(0) { count, batch in
      count + (batch.operation == .erase ? batch.mesh.vertices.count : 0)
    }
  }

  init(frame: CGRect, resources: SceneRenderResources = .shared) {
    self.resources = resources
    let gpu = InkRasterRenderer.shared
    let device = gpu.device
    // Display work has its own queue; a background readback cannot sit ahead of every live frame.
    commandQueue = device?.makeCommandQueue()
    textureLoader = device.map(MTKTextureLoader.init(device:))
    stableInkPipelineState = gpu.baseline
    inkPipelineState = gpu.ink
    eraserPipelineState = gpu.eraser

    super.init(frame: frame, device: device)

    colorPixelFormat = .bgra8Unorm
    // Empty physical owners retain routing and readiness, not MSAA attachments.
    sampleCount = 1
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    framebufferOnly = true
    enableSetNeedsDisplay = false
    // Mounting, not construction, admits a display loop. Derived offscreen
    // snapshots use InkRasterRenderer and never need a live drawable timer.
    isPaused = true
    preferredFramesPerSecond = 120
    autoResizeDrawable = true
    #if os(iOS)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    let metalLayer = layer as? CAMetalLayer
    #else
    wantsLayer = true
    let metalLayer = layer as? CAMetalLayer
    #endif
    metalLayer?.isOpaque = false
    metalLayer?.opacity = 0
    metalLayer?.presentsWithTransaction = false
    metalLayer?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer?.maximumDrawableCount = Self.framesInFlight
    delegate = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  isolated deinit { stableRasterTask?.cancel() }

  #if os(iOS)
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let screen = window?.windowScene?.screen { preferredFramesPerSecond = screen.maximumFramesPerSecond }
    mounted()
  }
  override func layoutSubviews() { super.layoutSubviews(); scheduleStableRasterIfNeeded() }
  #else
  override var isOpaque: Bool { false }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); mounted() }
  override func layout() { super.layout(); scheduleStableRasterIfNeeded() }
  #endif

  private func mounted() {
    guard window != nil else {
      // UIKit can retain a culled canvas beyond the end of its visible use.
      // Stop its timer even when no drawable arrives to finish the last draw.
      isPaused = true
      cancelPendingStableRaster()
      releaseDrawables()
      releaseGeometryBuffers()
      return
    }
    requestFrame()
    scheduleStableRasterIfNeeded()
  }

  func project(camera: SpatialCamera?, viewport: SpatialPoint) {
    guard spatialCamera != camera || spatialViewport != viewport else { return }
    spatialCamera = camera; spatialViewport = viewport
    beginStableContentUpdate()
    requestFrame()
  }

  private(set) var spatialMeshInstallCount = 0

  func finishSpatialPreparation() { drawingIsPreparing = false; requestFrame() }

  func applySpatial(_ mesh: SpatialInkMesh) {
    drawingIsPreparing = false
    spatialMeshInstallCount += 1
    beginStableContentUpdate()
    stableRasterTask?.cancel(); stableRasterTask = nil
    stableDrawing = nil; stableTexture = nil
    installedStableRasterKey = nil; pendingStableRasterKey = nil
    committedBatches = mesh.batches.map(CommittedBatch.init)
    discardActiveAction()
    requestFrame()
  }

  /// Replaces the page atomically. This is used for load, undo, and sync.
  func prepareForDrawing() {
    drawingIsPreparing = true
    beginStableContentUpdate()
  }

  func apply(_ drawing: PageInkDrawing) {
    drawingIsPreparing = false
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

  /// Replaces finished live batches after InkRasterRenderer has produced the
  /// exact durable pixels for the same drawing. A newer active gesture keeps
  /// the existing base and batches until its own durable drawing settles.
  func settle(_ drawing: PageInkDrawing) {
    drawingIsPreparing = false
    beginStableContentUpdate()
    stableRasterTask?.cancel()
    stableRasterTask = nil
    stableDrawingRevision &+= 1
    stableDrawing = drawing
    pendingStableRasterKey = nil
    scheduleStableRasterIfNeeded()
  }

  func beginSpatialAction() { spatialActionBase = committedBatches }
  func finishSpatialAction(keepingCommittedMesh: Bool) {
    if !keepingCommittedMesh, let base = spatialActionBase { committedBatches = base; requestFrame() }
    spatialActionBase = nil
  }

  /// Publishes the newest Pencil samples. Rendering happens on the display
  /// clock, never inside the touch callback.
  func displayActiveStroke(_ stroke: ActiveInkStroke) {
    if activeInkStroke !== stroke {
      beginStableContentUpdate()
      cancelPendingStableRaster()
      activeInkStroke = stroke
      activeEraserStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Composites the measured destination-out brush over the stable page.
  func displayActiveEraser(_ stroke: ActiveEraserStroke) {
    if activeEraserStroke !== stroke {
      beginStableContentUpdate()
      cancelPendingStableRaster()
      activeEraserStroke = stroke
      activeInkStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
    }
    requestFrame()
  }

  /// Finish only the measured tail of the live mesh. Predictions never enter
  /// the durable batch, and a long contact is not rebuilt at Pencil-up.
  func commitActiveStroke() { guard activeInkStroke != nil else { return }; commitMeasuredMesh() }
  func commitActiveEraser() { guard activeEraserStroke != nil else { return }; commitMeasuredMesh() }
  func commitActiveSpatialAction() { commitMeasuredMesh() }

  private func commitMeasuredMesh() {
    let identity: ObjectIdentifier
    let points: [PKStrokePoint]
    let color: SIMD4<Float>
    let operation: RenderOperation
    let changed: Int
    if let stroke = activeInkStroke {
      identity = ObjectIdentifier(stroke); points = stroke.measuredPoints
      let value = stroke.style.color.components
      color = .init(Float(value.red), Float(value.green), Float(value.blue), 1)
      operation = .ink; changed = stroke.consumeChangedStart()
    } else if let stroke = activeEraserStroke {
      identity = ObjectIdentifier(stroke); points = stroke.measuredPoints
      color = .init(1, 1, 1, 1); operation = .erase; changed = stroke.consumeChangedStart()
    } else { return }
    if builtActiveIdentity != identity { activeMesh = IncrementalInkMesh() }
    activeMesh.update(points: points, changedFrom: builtActiveIdentity == identity ? changed : 0, color: color)
    appendCommitted(activeMesh, operation: operation)
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
    guard window != nil else { isPaused = true; return }
    if presentEmptyContentIfReady() { return }
    sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal {
        inFlightSemaphore.signal()
      }
    }

    drawableRequestCount += 1
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

    guard let visible = prepareCommittedBuffers() else {
      encoder.endEncoding(); renderFailure = .resourceLimit
      return
    }
    let active = prepareActiveBuffer(in: frameSlot)
    if (activeInkStroke != nil || activeEraserStroke != nil) && !activeMesh.vertices.isEmpty && active == nil {
      encoder.endEncoding(); renderFailure = .resourceLimit
      return
    }

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
      for (batchIndex, chunkIndex) in visible {
        let batch = committedBatches[batchIndex]
        var transform = batch.mesh.projection.transform(camera: spatialCamera, viewport: spatialViewport)
        encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        draw(
          buffer: batch.buffers[chunkIndex]?.buffer,
          vertexCount: batch.mesh.chunks[chunkIndex].vertices.count,
          operation: batch.operation,
          with: encoder
        )
      }
      if let active {
        var identity = SIMD4<Float>(1, 1, 0, 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        draw(
          buffer: active.buffer,
          vertexCount: activeMesh.vertices.count,
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
    let submittedRevision = stableContentRevision
    let heldGeometry = visible.compactMap { committedBatches[$0.0].buffers[$0.1]?.reservation }
      + (activeBufferReservations[frameSlot].map { [$0] } ?? [])
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore, heldGeometry] buffer in
      inFlightSemaphore.signal()
      guard buffer.status == .completed else { return }
      Task { @MainActor [weak self, heldGeometry] in
        // Unmount/culling may already have released the canvas's references.
        // These bytes remain charged through the final GPU completion.
        withExtendedLifetime(heldGeometry) {}
        guard let self, window != nil, stableContentRevision == submittedRevision else { return }
        renderFailure = nil
        if !hasRevealedFirstFrame {
          hasRevealedFirstFrame = true
          // Completing a hidden drawable is not a capturable visible layer.
          // Reveal without a Core Animation fade, then require one more frame
          // before a cover snapshot can freeze these pixels.
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          #if os(iOS)
          layer.opacity = 1
          #else
          layer?.opacity = 1
          #endif
          CATransaction.commit()
          requestFrame()
          return
        }
        guard let presentedRevision,
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

    if activeInkStroke == nil, activeEraserStroke == nil { isPaused = true }
  }

  private func beginStableContentUpdate() {
    stableContentRevision &+= 1
    onRenderReadinessChange?(false)
  }

  private var stableRasterIsReady: Bool {
    guard !drawingIsPreparing else { return false }
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

    if drawing.isEmpty {
      installStableRaster(nil, for: key)
      return
    }

    let rasterBounds = CGRect(origin: .zero, size: key.size)
    let worker = Task.detached(priority: .userInitiated) {
      guard !Task.isCancelled else { return nil as StableRaster? }
      return Self.makeStableRaster(
          from: drawing,
          bounds: rasterBounds,
          scale: Self.stableRasterScale
        )
    }
    stableRasterTask = Task { [weak self] in
      let raster = await withTaskCancellationHandler {
        await worker.value
      } onCancel: { worker.cancel() }
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
        .SRGB: false,
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
    from drawing: PageInkDrawing,
    bounds: CGRect,
    scale: CGFloat
  ) -> StableRaster? {
    autoreleasepool {
      guard let image = InkRasterRenderer.shared.page(drawing,size:bounds.size,scale:scale) else {
        return nil
      }
      return StableRaster(image: image)
    }
  }

  private func requestFrame() {
    if presentEmptyContentIfReady() { return }
    // Mesh/raster completions may arrive after culling. Preserve their ready
    // content, but only a mounted surface can resume display execution.
    isPaused = window == nil
  }

  @discardableResult
  private func presentEmptyContentIfReady() -> Bool {
    guard stableRasterIsReady, stableTexture == nil,
      activeInkStroke == nil, activeEraserStroke == nil,
      committedBatches.allSatisfy({ $0.mesh.vertices.isEmpty })
    else { return false }
    isPaused = true
    if sampleCount != 1 { sampleCount = 1 }
    releaseDrawables()
    hasRevealedFirstFrame = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    #if os(iOS)
    layer.opacity = 0
    #else
    layer?.opacity = 0
    #endif
    CATransaction.commit()
    let revision = stableContentRevision
    // SwiftUI may be updating this owner now. Empty is a complete transparent
    // result, but readiness is delivered after the current publication pass.
    Task { @MainActor [weak self] in
      guard let self, stableContentRevision == revision, stableRasterIsReady,
        activeInkStroke == nil, activeEraserStroke == nil,
        presentedStableContentRevision != revision else { return }
      presentedStableContentRevision = revision
      onRenderReadinessChange?(true)
    }
    return true
  }

  private func discardActiveAction() {
    activeInkStroke = nil
    activeEraserStroke = nil
    builtActiveIdentity = nil
    builtActiveRevision = nil
    activeMesh = IncrementalInkMesh()
    activeBufferDirtyStarts = Array(repeating: 0, count: Self.framesInFlight)
    releaseActiveBuffers()
  }

  private func releaseActiveBuffers() {
    activeBuffers = Array(repeating: nil, count: Self.framesInFlight)
    activeBufferReservations = Array(repeating: nil, count: Self.framesInFlight)
    activeBufferCapacities = Array(repeating: 0, count: Self.framesInFlight)
    activeBufferDirtyStarts = Array(repeating: 0, count: Self.framesInFlight)
  }

  private func releaseGeometryBuffers() {
    for index in committedBatches.indices {
      committedBatches[index].buffers = Array(repeating: nil, count: committedBatches[index].mesh.chunks.count)
    }
    releaseActiveBuffers()
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
      builtActiveIdentity = nil
      builtActiveRevision = nil
      return nil
    }

    if builtActiveIdentity != identity || builtActiveRevision != revision {
      let changed = activeInkStroke?.consumeChangedStart() ?? activeEraserStroke?.consumeChangedStart() ?? 0
      if builtActiveIdentity != identity {
        activeMesh = IncrementalInkMesh()
        activeBufferDirtyStarts = Array(repeating: 0, count: Self.framesInFlight)
      }
      activeMesh.update(measured: measured, predicted: predicted, changedFrom: changed, color: color)
      for index in activeBufferDirtyStarts.indices {
        activeBufferDirtyStarts[index] = min(activeBufferDirtyStarts[index], activeMesh.rebuiltVertexStart)
      }
      builtActiveIdentity = identity
      builtActiveRevision = revision
    }
    guard !activeMesh.vertices.isEmpty else { return nil }

    let requiredLength = activeMesh.vertices.count * MemoryLayout<Vertex>.stride
    if requiredLength > activeBufferCapacities[slot] {
      let capacity = max(4096, nextPowerOfTwo(requiredLength))
      guard let reservation = resources.reserveDerivedBytes(capacity),
        let buffer = device?.makeBuffer(length: capacity, options: .storageModeShared)
      else { return nil }
      activeBufferCapacities[slot] = capacity
      activeBuffers[slot] = buffer
      activeBufferReservations[slot] = reservation
      buffer.label = "Active Pencil Stroke \(slot)"
      activeBufferDirtyStarts[slot] = 0
    }
    guard let buffer = activeBuffers[slot] else {
      return nil
    }
    // Every in-flight frame owns its slot. The CPU never overwrites vertices
    // that a preceding GPU command buffer may still be reading.
    let start = min(activeBufferDirtyStarts[slot], activeMesh.vertices.count)
    let offset = start * MemoryLayout<Vertex>.stride
    let length = requiredLength - offset
    if length > 0 {
      activeMesh.vertices.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress {
          buffer.contents().advanced(by: offset).copyMemory(from: base.advanced(by: offset), byteCount: length)
        }
      }
      activeUploadedByteCount += length
    }
    activeBufferDirtyStarts[slot] = activeMesh.vertices.count
    return (buffer, operation)
  }

  private func appendCommitted(
    _ active: IncrementalInkMesh,
    operation: RenderOperation
  ) {
    guard !active.vertices.isEmpty else { return }
    let projection = spatialCamera.map { SpatialInkMesh.Projection.screen($0, spatialViewport) } ?? .local
    // The contact already indexed its mutable tail on display frames. Sealing
    // it retains those arrays; it neither rescans nor copies the older history.
    committedBatches.append(.init(.init(tool: operation == .ink ? .pen : .eraser,
      vertices: active.vertices, chunks: active.chunks, projection: projection)))
  }

  private func prepareCommittedBuffers() -> [(Int, Int)]? {
    var visible: [(Int, Int)] = []
    visibleCommittedVertexCount = 0
    let viewport = CGRect(origin: .zero, size: bounds.size)
    for batchIndex in committedBatches.indices {
      let mesh = committedBatches[batchIndex].mesh
      let transform = mesh.projection.transform(camera: spatialCamera, viewport: spatialViewport)
      for chunkIndex in mesh.chunks.indices {
        let chunk = mesh.chunks[chunkIndex]
        if chunk.intersects(viewport: viewport, transform: transform) {
          visible.append((batchIndex, chunkIndex))
          visibleCommittedVertexCount += chunk.vertices.count
        } else {
          committedBatches[batchIndex].buffers[chunkIndex] = nil
        }
      }
    }
    visibleCommittedChunkCount = visible.count
    for (batchIndex, chunkIndex) in visible where committedBatches[batchIndex].buffers[chunkIndex] == nil {
      let mesh = committedBatches[batchIndex].mesh
      guard let buffer = makeBuffer(for: mesh.vertices, range: mesh.chunks[chunkIndex].vertices) else { return nil }
      committedBatches[batchIndex].buffers[chunkIndex] = buffer
    }
    return visible
  }

  private func makeBuffer(for vertices: [Vertex], range: Range<Int>) -> GeometryBuffer? {
    guard let device, !range.isEmpty,
      let reservation = resources.reserveDerivedBytes(range.count * MemoryLayout<Vertex>.stride) else { return nil }
    let buffer = vertices.withUnsafeBytes { bytes -> (any MTLBuffer)? in
      guard let baseAddress = bytes.baseAddress else { return nil }
      return device.makeBuffer(bytes: baseAddress.advanced(by: range.lowerBound * MemoryLayout<Vertex>.stride),
        length: reservation.byteCount, options: .storageModeShared)
    }
    guard let buffer else { return nil }
    buffer.label = "Visible Notebook Ink Chunk"
    return .init(buffer: buffer, reservation: reservation)
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

  private func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
  }
}

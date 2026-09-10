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
  fileprivate enum RenderOperation: Equatable {
    case ink
    case erase
  }

  private typealias Vertex = SpatialInkGeometry.Vertex

  fileprivate struct SpatialTargetLayout: Equatable {
    let size: CGSize
    let displayScale: Double
    var pixelSize: CGSize {
      .init(width: ceil(size.width * displayScale), height: ceil(size.height * displayScale))
    }
    func tileGrid() throws -> (columns: Int, rows: Int) {
      let pixels = pixelSize
      guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
        displayScale.isFinite, displayScale > 0, pixels.width.isFinite, pixels.height.isFinite,
        (1...16_384).contains(pixels.width), (1...16_384).contains(pixels.height) else {
        throw SceneRenderError.resourceLimit
      }
      let columns = (Int(pixels.width) + SpatialTile.side - 1) / SpatialTile.side
      let rows = (Int(pixels.height) + SpatialTile.side - 1) / SpatialTile.side
      guard columns * rows <= 256 else { throw SceneRenderError.resourceLimit }
      return (columns, rows)
    }
  }

  /// Fixed-size pools survive a layout change. A candidate borrows their next
  /// drawables without resizing, relocating or presenting the installed ones.
  /// The same Canvas remains the sole source, input and physical scene owner.
  @MainActor
  fileprivate final class SpatialTile {
    nonisolated static let side = 512
    let layer: CAMetalLayer
    let multisample: (any MTLTexture)?
    let bytes: RasterReservation
    let physical: ScenePhysicalOwnerLease?
    let drawableByteCeiling: Int
    init(layer: CAMetalLayer, multisample: (any MTLTexture)?,
      bytes: RasterReservation, physical: ScenePhysicalOwnerLease?, drawableByteCeiling: Int) {
      self.layer = layer; self.multisample = multisample
      self.bytes = bytes; self.physical = physical; self.drawableByteCeiling = drawableByteCeiling
    }
    isolated deinit { layer.removeFromSuperlayer() }
  }

  @MainActor
  fileprivate final class SpatialTarget {
    let layout: SpatialTargetLayout
    let columns: Int
    let tiles: [SpatialTile]
    init(layout: SpatialTargetLayout, columns: Int, tiles: [SpatialTile]) {
      self.layout = layout; self.columns = columns; self.tiles = tiles
    }
    func detach() { for tile in tiles { tile.layer.removeFromSuperlayer() } }
    func pixelOrigin(_ index: Int) -> CGPoint {
      .init(x: (index % columns) * SpatialTile.side, y: (index / columns) * SpatialTile.side)
    }
    func viewport(_ index: Int) -> MTLViewport {
      let origin = pixelOrigin(index), pixels = layout.pixelSize
      return .init(originX: -origin.x, originY: -origin.y, width: pixels.width,
        height: pixels.height, znear: 0, zfar: 1)
    }
    func logicalRect(_ index: Int) -> CGRect {
      let origin = pixelOrigin(index), pixels = layout.pixelSize
      let scaleX = layout.size.width / pixels.width, scaleY = layout.size.height / pixels.height
      return .init(x: origin.x * scaleX, y: origin.y * scaleY,
        width: CGFloat(SpatialTile.side) * scaleX, height: CGFloat(SpatialTile.side) * scaleY)
    }
  }

  fileprivate struct GeometryBuffer {
    let buffer: any MTLBuffer
    let reservation: RasterReservation
  }

  fileprivate struct CommittedBatch {
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
  /// A retained surface submits one GPU frame at a time beside its shown frame.
  /// Preparation uses that same second slot, never a second full drawable pool.
  nonisolated static let spatialFramesInFlight = 2
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
  private(set) var installedSpatialSource: SpatialInkInstalledSource?
  private(set) var spatialSourceGeneration: UInt64 = 0
  private var spatialHandoffRetains = 0
  private var spatialDrawableScale: Double?
  private var spatialTarget: SpatialTarget?
  var spatialMultisampleStorageMode: MTLStorageMode? { spatialTarget?.tiles.first?.multisample?.storageMode }
  var spatialMultisampleAllocatedBytes: Int { spatialTarget?.tiles.reduce(0) { $0 + ($1.multisample?.allocatedSize ?? 0) } ?? 0 }
  var spatialDrawableAccountedBytes: Int { spatialTarget?.tiles.reduce(0) { $0 + $1.bytes.byteCount } ?? 0 }
  var spatialDrawableByteCeiling: Int { spatialTarget?.tiles.reduce(0) { $0 + $1.drawableByteCeiling } ?? 0 }
  var spatialTilePoolIDs: [ObjectIdentifier] { spatialTarget?.tiles.map(ObjectIdentifier.init) ?? [] }
  private var physicalAdmission: ScenePhysicalOwnerLease?
  private var submittedFrameCount = 0
  private var submittedPresentationCount = 0
  private var frameDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var spatialHandoffIsStopping = false
  private var spatialStagingID: UUID?
  private weak var stagedSpatialFrame: PreparedSpatialFrame?
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
  var hasSpatialInkGeometry: Bool {
    !committedBatches.isEmpty || activeInkStroke != nil || activeEraserStroke != nil
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
      if spatialHandoffRetains == 0 {
        releaseDrawables()
        releaseGeometryBuffers()
        spatialTarget?.detach(); spatialTarget = nil
      }
      return
    }
    requestFrame()
    scheduleStableRasterIfNeeded()
  }

  /// The same physical board layer moves between the active scene, its portal
  /// and the preparation host. Its admitted backing survives those brief
  /// hierarchy changes; a released/cancelled owner follows ordinary teardown.
  func holdPhysicalAdmission(_ admission: ScenePhysicalOwnerLease) { physicalAdmission = admission }
  func releasePhysicalAdmission() { physicalAdmission = nil }

  /// Cancellation may revoke a candidate immediately, but its submitted Metal
  /// work owns both the byte and physical admission until completion.
  func finishSpatialHandoffFrames() async {
    spatialHandoffIsStopping = true
    isPaused = true
    if submittedFrameCount > 0 || submittedPresentationCount > 0 {
      await withCheckedContinuation { frameDrainWaiters.append($0) }
    }
    releaseDrawables()
    // A dismantled UIKit configuration may still retain this Canvas. Terminal
    // drain must release its source and CPU mesh too. Temporary unmount and
    // parking never enter this terminal path.
    cancelPendingStableRaster()
    stableDrawing = nil; stableTexture = nil
    installedStableRasterKey = nil; pendingStableRasterKey = nil
    committedBatches.removeAll(); spatialActionBase = nil
    discardActiveAction()
    installedSpatialSource = nil; spatialSourceGeneration &+= 1
    spatialStagingID = nil
    visibleCommittedVertexCount = 0; visibleCommittedChunkCount = 0
    spatialTarget?.detach(); spatialTarget = nil
    hasRevealedFirstFrame = false
    presentedStableContentRevision = nil
  }

  func retainForSpatialHandoff(displayScale: Double) -> SpatialInkCanvasRetention {
    precondition(displayScale.isFinite && displayScale > 0)
    spatialHandoffRetains += 1
    spatialDrawableScale = displayScale
    autoResizeDrawable = false
    return SpatialInkCanvasRetention(view: self)
  }

  fileprivate func releaseSpatialHandoff() {
    guard spatialHandoffRetains > 0 else { return }
    spatialHandoffRetains -= 1
    if spatialHandoffRetains == 0, window == nil {
      isPaused = true; releaseDrawables(); releaseGeometryBuffers()
      spatialTarget?.detach(); spatialTarget = nil
    }
  }

  private func admitSpatialDrawable(samples: Int) -> Bool {
    guard let spatialDrawableScale else { return true }
    if spatialTarget != nil { return true }
    do {
      let target = try makeSpatialTarget(layout: .init(size: bounds.size, displayScale: spatialDrawableScale), samples: samples)
      installSpatialTarget(target)
      return true
    } catch { renderFailure = .resourceLimit; return false }
  }

  func needsSpatialTarget(size: SpatialPoint, displayScale: Double) -> Bool {
    bounds.size != CGSize(width: size.x, height: size.y) || spatialDrawableScale != displayScale
  }

  private func makeSpatialTarget(layout: SpatialTargetLayout, samples: Int) throws -> SpatialTarget {
    let (columns, rows) = try layout.tileGrid()
    var tiles: [SpatialTile] = []
    for index in 0..<(columns * rows) {
      if let installed = spatialTarget, index < installed.tiles.count { tiles.append(installed.tiles[index]) }
      else { tiles.append(try makeSpatialTile(samples: samples)) }
    }
    return .init(layout: layout, columns: columns, tiles: tiles)
  }

  private func makeSpatialTile(samples: Int) throws -> SpatialTile {
    guard let device else { throw SceneRenderError.resourceLimit }
    let width = SpatialTile.side, height = SpatialTile.side
    let memoryless = device.supportsFamily(.apple1)
    let drawableDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat,
      width: width, height: height, mipmapped: false)
    drawableDescriptor.storageMode = .private; drawableDescriptor.usage = .renderTarget
    func allocationSize(_ descriptor: MTLTextureDescriptor) -> Int {
      let allocation = device.heapTextureSizeAndAlign(descriptor: descriptor)
      let alignment = max(1, allocation.align)
      return ((allocation.size + alignment - 1) / alignment) * alignment
    }
    // CAMetalLayer does not expose its IOSurface stride before nextDrawable.
    // Admit Metal's aligned footprint and an aligned-row floor, then validate
    // every actual drawable before encoding. This is bounded accounting, not
    // an assertion that the pool's driver-managed RSS is exactly this number.
    let row = ((width * 4 + 255) / 256) * 256
    let drawableBytes = max(allocationSize(drawableDescriptor), row * height)
    var descriptor: MTLTextureDescriptor?
    var attachmentBytes = 0
    if samples > 1 {
      let value = MTLTextureDescriptor()
      value.textureType = .type2DMultisample; value.pixelFormat = colorPixelFormat
      value.width = width; value.height = height; value.sampleCount = samples
      value.usage = .renderTarget; value.storageMode = memoryless ? .memoryless : .private
      descriptor = value
      if !memoryless { attachmentBytes = allocationSize(value) }
    }
    let bytes = drawableBytes * Self.spatialFramesInFlight + attachmentBytes
    guard let reservation = resources.reserveDerivedBytes(bytes, priority: physicalAdmission?.allocationPriority ?? .input, owner: physicalAdmission)
    else { throw SceneRenderError.resourceLimit }
    let multisample = descriptor.flatMap { device.makeTexture(descriptor: $0) }
    guard descriptor == nil || multisample != nil,
      (multisample?.allocatedSize ?? 0) <= attachmentBytes else { throw SceneRenderError.resourceLimit }
    let layer = CAMetalLayer()
    layer.device = device; layer.pixelFormat = colorPixelFormat; layer.framebufferOnly = true
    layer.isOpaque = false; layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.maximumDrawableCount = Self.spatialFramesInFlight; layer.presentsWithTransaction = false
    layer.drawableSize = .init(width: width, height: height)
    return .init(layer: layer, multisample: multisample, bytes: reservation,
      physical: physicalAdmission, drawableByteCeiling: drawableBytes)
  }

  private func installSpatialTarget(_ target: SpatialTarget?) {
    let retained = Set(target?.tiles.map(ObjectIdentifier.init) ?? [])
    for tile in spatialTarget?.tiles ?? [] where !retained.contains(ObjectIdentifier(tile)) {
      tile.layer.removeFromSuperlayer()
    }
    spatialTarget = target
    guard let target else { return }
    let pixels = target.layout.pixelSize
    for (index, tile) in target.tiles.enumerated() {
      #if os(iOS)
        layer.masksToBounds = true
        layer.addSublayer(tile.layer)
      #else
        layer?.masksToBounds = true
        layer?.addSublayer(tile.layer)
      #endif
      tile.layer.frame = target.logicalRect(index)
    }
    drawableSize = pixels
  }

  private func spatialRenderPass(target: SpatialTile, drawable: any CAMetalDrawable) -> MTLRenderPassDescriptor {
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target.multisample ?? drawable.texture
    descriptor.colorAttachments[0].resolveTexture = target.multisample == nil ? nil : drawable.texture
    descriptor.colorAttachments[0].storeAction = target.multisample == nil ? .store : .multisampleResolve
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = clearColor
    return descriptor
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
    installedSpatialSource = nil
    spatialSourceGeneration &+= 1
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

  /// Source and geometry are installed by the same physical owner. This is a
  /// source receipt, not a GPU-presented or visible-pixels acknowledgement.
  func installSpatialSource(_ journal: SpatialInkJournal?, on surface: SurfaceID) {
    installedSpatialSource = journal.map { .init(surface: surface, journal: $0) }
    spatialSourceGeneration &+= 1
  }

  func appendInstalledSpatialAction(_ action: SpatialInkAction) {
    installedSpatialSource = installedSpatialSource?.appending(action)
    spatialSourceGeneration &+= 1
  }

  /// Replaces the page atomically. This is used for load, undo, and sync.
  func prepareForDrawing() {
    drawingIsPreparing = true
    beginStableContentUpdate()
  }

  func apply(_ drawing: PageInkDrawing) {
    installedSpatialSource = nil
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

  func beginSpatialAction() {
    // A new accepted contact revokes private preparation immediately. The
    // pending GPU command retains its own drawable but never delays samples.
    cancelSpatialStaging()
    spatialActionBase = committedBatches
  }
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
    guard window != nil, !spatialHandoffIsStopping, spatialStagingID == nil else { isPaused = true; return }
    if spatialDrawableScale != nil, submittedFrameCount > 0 || submittedPresentationCount > 0 { return }
    if presentEmptyContentIfReady() { return }
    let samples = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    guard admitSpatialDrawable(samples: samples) else { return }
    // A retained scene canvas owns its explicit MSAA attachment. Asking
    // MTKView for another implicit attachment would double the allocation.
    sampleCount = spatialDrawableScale == nil ? samples : 1
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal {
        inFlightSemaphore.signal()
      }
    }

    drawableRequestCount += 1
    guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    var passes: [(MTLRenderPassDescriptor, any CAMetalDrawable, MTLViewport?, CGRect?)] = []
    if let target = spatialTarget {
      for (index, tile) in target.tiles.enumerated() {
        guard let drawable = tile.layer.nextDrawable(), drawable.texture.allocatedSize <= tile.drawableByteCeiling else {
          renderFailure = .resourceLimit; return
        }
        passes.append((spatialRenderPass(target: tile, drawable: drawable), drawable, target.viewport(index), target.logicalRect(index)))
      }
    } else {
      guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
      passes.append((pass, drawable, nil, nil))
    }
    guard let visible = prepareCommittedBuffers() else { renderFailure = .resourceLimit; return }
    let active = prepareActiveBuffer(in: frameSlot)
    if (activeInkStroke != nil || activeEraserStroke != nil) && !activeMesh.vertices.isEmpty && active == nil {
      renderFailure = .resourceLimit; return
    }
    for (descriptor, _, viewport, clip) in passes {
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].clearColor = clearColor
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
      if let viewport { encoder.setViewport(viewport) }
      if let stableTexture, let stableInkPipelineState {
        encoder.label = "Stable Notebook Ink"
        encoder.setRenderPipelineState(stableInkPipelineState)
        encoder.setFragmentTexture(stableTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      }
      encodeSpatial(batches: committedBatches, visible: visible, active: active,
        camera: spatialCamera, viewport: spatialViewport, size: bounds.size, clip: clip, encoder: encoder)
      encoder.endEncoding()
    }
    presentsWithTransaction = false
    for tile in spatialTarget?.tiles ?? [] { tile.layer.presentsWithTransaction = false }
    for (_, drawable, _, _) in passes { commandBuffer.present(drawable) }
    let presentedRevision: UInt64? =
      activeInkStroke == nil
        && activeEraserStroke == nil
        && stableRasterIsReady
      ? stableContentRevision : nil
    let submittedRevision = stableContentRevision
    let heldGeometry = visible.compactMap { committedBatches[$0.0].buffers[$0.1]?.reservation }
      + (activeBufferReservations[frameSlot].map { [$0] } ?? [])
    submittedFrameCount += 1
    let physical = physicalAdmission
    let target = spatialTarget
    commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore, heldGeometry, physical, target] buffer in
      inFlightSemaphore.signal()
      let completed = buffer.status == .completed
      Task { @MainActor [weak self, heldGeometry, physical, target] in
        // Unmount/culling may already have released the canvas's references.
        // These bytes remain charged through the final GPU completion.
        withExtendedLifetime((heldGeometry, physical, target)) {}
        guard let self else { return }
        finishSubmittedFrame()
        guard completed, !spatialHandoffIsStopping, window != nil,
          stableContentRevision == submittedRevision else { return }
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

  private func encodeSpatial(batches: [CommittedBatch], visible: [(Int, Int)],
    active: (buffer: any MTLBuffer, operation: RenderOperation)?, camera: SpatialCamera?,
    viewport: SpatialPoint, size: CGSize, clip: CGRect? = nil, encoder: any MTLRenderCommandEncoder) {
    guard inkPipelineState != nil, eraserPipelineState != nil else { return }
    encoder.label = "Notebook Ink"
    var viewportSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
    encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    for (batchIndex, chunkIndex) in visible {
      let batch = batches[batchIndex]
      var transform = batch.mesh.projection.transform(camera: camera, viewport: viewport)
      if let clip, !batch.mesh.chunks[chunkIndex].intersects(viewport: clip, transform: transform) { continue }
      encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
      draw(buffer: batch.buffers[chunkIndex]?.buffer, vertexCount: batch.mesh.chunks[chunkIndex].vertices.count,
        operation: batch.operation, with: encoder)
    }
    if let active {
      var identity = SIMD4<Float>(1, 1, 0, 0)
      encoder.setVertexBytes(&identity, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
      draw(buffer: active.buffer, vertexCount: activeMesh.vertices.count, operation: active.operation, with: encoder)
    }
  }

  private func cancelSpatialStaging(id: UUID? = nil) {
    guard let current = spatialStagingID, id == nil || current == id else { return }
    spatialStagingID = nil
    stagedSpatialFrame?.revoke()
    stagedSpatialFrame = nil
    requestFrame()
  }

  @MainActor
  final class PreparedSpatialFrame {
    fileprivate let id: UUID
    fileprivate weak var canvas: InkCanvasView?
    fileprivate let sourceGeneration: UInt64
    fileprivate let contentRevision: UInt64
    fileprivate var batches: [CommittedBatch]
    fileprivate let replacesMesh: Bool
    fileprivate let layout: SpatialTargetLayout
    fileprivate let viewport: SpatialPoint
    fileprivate var target: SpatialTarget?
    fileprivate var drawables: [any CAMetalDrawable]
    fileprivate var ready = false
    fileprivate var installed = false
    private var revoked = false
    private var gpuCompleted = false
    private var transactionCommitted = false
    private var transactionCompletion: (@MainActor () -> Void)?
    func afterPresentationTransaction(_ completion: @escaping @MainActor () -> Void) {
      precondition(transactionCompletion == nil, "One cohort observes this native publication")
      if transactionCommitted { completion() } else { transactionCompletion = completion }
    }
    fileprivate func presentationTransactionCommitted() {
      transactionCommitted = true
      // The installed Canvas now owns its pools. A retained scene receipt must
      // not occupy a drawable slot or keep retired pools alive indefinitely.
      drawables.removeAll(); target = nil; batches.removeAll()
      let completion = transactionCompletion; transactionCompletion = nil
      completion?()
    }
    fileprivate func revoke() {
      revoked = true
      if gpuCompleted { drawables.removeAll(); target = nil; batches.removeAll() }
    }
    fileprivate func completeGPU() {
      gpuCompleted = true
      if revoked { drawables.removeAll(); target = nil; batches.removeAll() }
    }
    fileprivate init(id: UUID, canvas: InkCanvasView, batches: [CommittedBatch], replacesMesh: Bool,
      layout: SpatialTargetLayout, viewport: SpatialPoint, target: SpatialTarget?, drawables: [any CAMetalDrawable]) {
      self.id = id; self.canvas = canvas; self.batches = batches; self.drawables = drawables
      self.replacesMesh = replacesMesh; self.layout = layout; self.viewport = viewport; self.target = target
      sourceGeneration = canvas.spatialSourceGeneration; contentRevision = canvas.stableContentRevision
    }
    var isValid: Bool {
      guard let canvas else { return false }
      return ready && !revoked && !installed && !canvas.spatialHandoffIsStopping && canvas.spatialStagingID == id
        && canvas.spatialSourceGeneration == sourceGeneration && canvas.stableContentRevision == contentRevision
        && canvas.spatialActionBase == nil
    }
    isolated deinit { if !installed { canvas?.cancelSpatialStaging(id: id) } }
  }

  /// Source and layout changes borrow fixed pools. Only growth allocates new
  /// tiles. No installed layer moves or presents before the whole candidate
  /// validates; cancellation releases private drawables, not displayed pixels.
  func prepareSpatialFrame(_ mesh: SpatialInkMesh?, size: SpatialPoint, displayScale: Double) async throws -> PreparedSpatialFrame {
    try Task.checkCancellation()
    guard !spatialHandoffIsStopping, spatialActionBase == nil, spatialStagingID == nil,
      let commandQueue else { throw CancellationError() }
    let id = UUID(); spatialStagingID = id; isPaused = true
    var succeeded = false
    defer { if !succeeded { cancelSpatialStaging(id: id) } }
    if submittedFrameCount > 0 || submittedPresentationCount > 0 {
      await withCheckedContinuation { frameDrainWaiters.append($0) }
    }
    try Task.checkCancellation()
    guard spatialStagingID == id, !spatialHandoffIsStopping else { throw CancellationError() }
    let oldSource = spatialSourceGeneration, oldProjection = stableContentRevision
    let layout = SpatialTargetLayout(size: .init(width: size.x, height: size.y), displayScale: displayScale)
    _ = try layout.tileGrid()
    let viewport = size, camera = spatialCamera
    var batches = mesh?.batches.map(CommittedBatch.init) ?? committedBatches
    let visible = try prepareBuffers(in: &batches, camera: camera, viewport: viewport, size: layout.size)
    if visible.isEmpty {
      let result = PreparedSpatialFrame(id: id, canvas: self, batches: batches, replacesMesh: mesh != nil,
        layout: layout, viewport: viewport, target: nil, drawables: [])
      result.completeGPU(); result.ready = true; succeeded = true; stagedSpatialFrame = result
      return result
    }
    let samples = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    let target: SpatialTarget
    if let installed = spatialTarget, installed.layout == layout { target = installed }
    else { target = try makeSpatialTarget(layout: layout, samples: samples) }
    guard let command = commandQueue.makeCommandBuffer() else { throw SceneRenderError.resourceLimit }
    var drawables: [any CAMetalDrawable] = []
    for (index, tile) in target.tiles.enumerated() {
      guard let drawable = tile.layer.nextDrawable(), drawable.texture.allocatedSize <= tile.drawableByteCeiling else {
        throw SceneRenderError.resourceLimit
      }
      drawables.append(drawable)
      let descriptor = spatialRenderPass(target: tile, drawable: drawable)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { throw SceneRenderError.resourceLimit }
      encoder.setViewport(target.viewport(index))
      encodeSpatial(batches: batches, visible: visible, active: nil,
        camera: camera, viewport: viewport, size: layout.size, clip: target.logicalRect(index), encoder: encoder)
      encoder.endEncoding()
    }
    let result = PreparedSpatialFrame(id: id, canvas: self, batches: batches, replacesMesh: mesh != nil,
      layout: layout, viewport: viewport, target: target, drawables: drawables)
    drawables.removeAll(); stagedSpatialFrame = result
    submittedFrameCount += 1
    let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      command.addCompletedHandler { [weak self, result] command in
        let completed = command.status == .completed
        Task { @MainActor [weak self, result] in
          result.completeGPU()
          if let self { finishSubmittedFrame() }
          continuation.resume(returning: completed)
        }
      }
      command.commit()
    }
    try Task.checkCancellation()
    guard completed else { throw SceneRenderError.resourceLimit }
    guard spatialStagingID == id, spatialSourceGeneration == oldSource,
      stableContentRevision == oldProjection, spatialActionBase == nil else { throw CancellationError() }
    result.ready = true; succeeded = true
    return result
  }

  /// Called only after every source/projection in the candidate validated in
  /// this main-actor turn. GPU work is complete; this is not an observed-frame
  /// receipt. The caller publishes its matching static cohort in the same turn.
  func installSpatialFrame(_ frame: PreparedSpatialFrame, journal: SpatialInkJournal, surface: SurfaceID) {
    precondition(frame.canvas === self && frame.isValid)
    frame.installed = true
    spatialSourceGeneration &+= 1; stableContentRevision &+= 1
    if frame.replacesMesh { spatialMeshInstallCount += 1 }
    stableDrawing = nil; stableTexture = nil; drawingIsPreparing = false
    installedStableRasterKey = nil; pendingStableRasterKey = nil
    committedBatches = frame.batches; discardActiveAction()
    installedSpatialSource = .init(surface: surface, journal: journal)
    let revision = stableContentRevision, generation = spatialSourceGeneration
    presentedStableContentRevision = nil
    let retiredTarget = spatialTarget
    submittedPresentationCount += 1
    CATransaction.begin(); CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock { [weak self, frame, retiredTarget] in
      Task { @MainActor [weak self, frame, retiredTarget] in
        withExtendedLifetime(retiredTarget) {}
        // A committed layer transaction is stronger than completed GPU work,
        // but is not an OS drawable-presented timestamp. The Simulator SDK
        // does not expose MTLDrawable.addPresentedHandler.
        if let self, !spatialHandoffIsStopping, stableContentRevision == revision,
          spatialSourceGeneration == generation {
          presentedStableContentRevision = revision
          onRenderReadinessChange?(true)
        }
        frame.presentationTransactionCommitted()
        if let self {
          submittedPresentationCount -= 1
          resumeSpatialDrainIfReady()
        }
      }
    }
    bounds.size = frame.layout.size
    spatialViewport = frame.viewport; spatialDrawableScale = frame.layout.displayScale
    installSpatialTarget(frame.target)
    for tile in frame.target?.tiles ?? [] { tile.layer.presentsWithTransaction = true }
    #if os(iOS)
      layer.opacity = frame.drawables.isEmpty ? 0 : 1
    #else
      layer?.opacity = frame.drawables.isEmpty ? 0 : 1
    #endif
    for drawable in frame.drawables { drawable.present() }
    CATransaction.commit()
    spatialStagingID = nil
    stagedSpatialFrame = nil
    hasRevealedFirstFrame = !frame.drawables.isEmpty
    isPaused = true
  }

  private func finishSubmittedFrame() {
    submittedFrameCount -= 1
    resumeSpatialDrainIfReady()
  }

  private func resumeSpatialDrainIfReady() {
    if submittedFrameCount == 0, submittedPresentationCount == 0 {
      let waiters = frameDrainWaiters; frameDrainWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private func beginStableContentUpdate() {
    cancelSpatialStaging()
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
    isPaused = window == nil || spatialStagingID != nil || spatialHandoffIsStopping
  }

  @discardableResult
  private func presentEmptyContentIfReady() -> Bool {
    guard !spatialHandoffIsStopping, spatialStagingID == nil, stableRasterIsReady, stableTexture == nil,
      activeInkStroke == nil, activeEraserStroke == nil,
      committedBatches.allSatisfy({ $0.mesh.vertices.isEmpty })
    else { return false }
    isPaused = true
    if sampleCount != 1 { sampleCount = 1 }
    releaseDrawables()
    spatialTarget?.detach(); spatialTarget = nil
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
      guard let self, !spatialHandoffIsStopping, stableContentRevision == revision, stableRasterIsReady,
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
      guard let reservation = resources.reserveDerivedBytes(capacity, priority: physicalAdmission?.allocationPriority ?? .input, owner: physicalAdmission),
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
    guard let visible = try? prepareBuffers(in: &committedBatches,
      camera: spatialCamera, viewport: spatialViewport, size: bounds.size) else { return nil }
    visibleCommittedVertexCount = visible.reduce(0) { $0 + committedBatches[$1.0].mesh.chunks[$1.1].vertices.count }
    visibleCommittedChunkCount = visible.count
    return visible
  }

  private func prepareBuffers(in batches: inout [CommittedBatch], camera: SpatialCamera?,
    viewport: SpatialPoint, size: CGSize) throws -> [(Int, Int)] {
    var visible: [(Int, Int)] = []
    let viewportRect = CGRect(origin: .zero, size: size)
    for batchIndex in batches.indices {
      let mesh = batches[batchIndex].mesh
      let transform = mesh.projection.transform(camera: camera, viewport: viewport)
      for chunkIndex in mesh.chunks.indices {
        let chunk = mesh.chunks[chunkIndex]
        if chunk.intersects(viewport: viewportRect, transform: transform) { visible.append((batchIndex, chunkIndex)) }
        else { batches[batchIndex].buffers[chunkIndex] = nil }
      }
    }
    for (batchIndex, chunkIndex) in visible where batches[batchIndex].buffers[chunkIndex] == nil {
      let mesh = batches[batchIndex].mesh
      guard let buffer = makeBuffer(for: mesh.vertices, range: mesh.chunks[chunkIndex].vertices) else { throw SceneRenderError.resourceLimit }
      batches[batchIndex].buffers[chunkIndex] = buffer
    }
    return visible
  }

  private func makeBuffer(for vertices: [Vertex], range: Range<Int>) -> GeometryBuffer? {
    guard let device, !range.isEmpty,
      let reservation = resources.reserveDerivedBytes(range.count * MemoryLayout<Vertex>.stride,
        priority: physicalAdmission?.allocationPriority ?? .input, owner: physicalAdmission) else { return nil }
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

@MainActor
final class SpatialInkCanvasRetention {
  private var view: InkCanvasView?
  fileprivate init(view: InkCanvasView) { self.view = view }
  func release() {
    let owner = view; view = nil
    owner?.releaseSpatialHandoff()
  }
  isolated deinit { release() }
}

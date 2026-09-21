import ImageIO
import MetalKit
import NotebookCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The accepted contact is the measured source, not a retained PencilKit array.
/// Its display mesh and predictions are disposable projections of this owner.
@MainActor
final class ActiveInkStroke {
  let style: PenStyle
  let projection: InkSampleProjection
  private(set) var measured: InkSampleRelations.Contact
  private(set) var predicted: [SpatialInkSample] = []
  private(set) var revision: UInt64 = 0
  private var changedFrom = 0
  init(style: PenStyle,sourceID: UUID = UUID(),span: Int = 0,projection: InkSampleProjection = .init()) {
    self.style=style;self.projection=projection
    let c=style.color.components
    measured = .init(sourceID:sourceID,span:span,header:.init(tool:.pen,color:.init(red:c.red,green:c.green,blue:c.blue)))
  }
  func consumeChangedStart() -> Int { defer { changedFrom=measured.count };return changedFrom }
  func replaceMeasuredTail(from startIndex: Int,with samples: [SpatialInkSample]) {
    let start=min(max(startIndex,0),measured.count)
    changedFrom=min(changedFrom,start);measured.replaceTail(from:start,with:samples);revision &+= 1
  }
  func replacePredictions(with samples: [SpatialInkSample]) { predicted=samples;revision &+= 1 }
}

@MainActor
final class ActiveEraserStroke {
  let projection: InkSampleProjection
  private(set) var measured: InkSampleRelations.Contact
  private(set) var revision: UInt64 = 0
  private var changedFrom = 0
  init(sourceID: UUID = UUID(),span: Int = 0,color: SpatialInkColor = .black,projection: InkSampleProjection = .init()) {
    self.projection=projection;measured = .init(sourceID:sourceID,span:span,header:.init(tool:.eraser,color:color))
  }
  func consumeChangedStart() -> Int { defer { changedFrom=measured.count };return changedFrom }
  func replaceMeasuredTail(from startIndex: Int,with samples: [SpatialInkSample]) {
    let start=min(max(startIndex,0),measured.count)
    changedFrom=min(changedFrom,start);measured.replaceTail(from:start,with:samples);revision &+= 1
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

  private typealias Node = SpatialInkGeometry.Node

  /// Board motion uses the slack in the fixed-size native tile pools first.
  /// One bounded guard band, not another viewport, keeps small pans off the GPU.
  static func sceneBackingSize(viewport: SpatialPoint, displayScale: Double) -> SpatialPoint {
    let side = Double(SpatialTile.side)
    func extent(_ points: Double) -> Double {
      ceil((points * displayScale + 128) / side) * side / displayScale
    }
    return .init(x: extent(viewport.x), y: extent(viewport.y))
  }

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

  fileprivate final class PreparedGeometry {
    let chunk: SpatialInkGeometry.PreparedChunk
    let reservation: RasterReservation
    init(_ chunk: SpatialInkGeometry.PreparedChunk,reservation: RasterReservation) { self.chunk=chunk;self.reservation=reservation }
  }
  fileprivate struct GeometryBuffer {
    let geometry: PreparedGeometry
    let buffer: any MTLBuffer
    let reservation: RasterReservation
    let nodeCount: Int
    let level: Int
    var isVisible = true
  }

  fileprivate struct CommittedBatch {
    let renderID = UUID()
    let mesh: SpatialInkMesh.Batch
    var buffers: [Range<Int>: GeometryBuffer] = [:]
    var pageAction: PageInkAction?
    var pageCommit: UInt64 = 0
    var operation: RenderOperation { mesh.tool == .pen ? .ink : .erase }
    init(_ mesh: SpatialInkMesh.Batch) {
      self.mesh = mesh
    }
  }

  private struct TileToken: Equatable {
    let source: UUID
    let chunk: Range<Int>
    let revision: UInt64
    let level: Int
    let transform: SIMD4<Float>
  }
  private struct TileSignature: Equatable {
    let tokens: [TileToken]
    let baseline: ObjectIdentifier?
  }
  private var drawnTiles: (target: ObjectIdentifier, signatures: [TileSignature])?
  private var needsRevealedFrame = false
  private var activeRenderID = UUID()
  private(set) var lastRenderedTileCount = 0
  private(set) var submittedTileCount = 0
  var residentCommittedNodeCount: Int {
    committedBatches.reduce(0) { $0+$1.buffers.values.reduce(0) { $0+$1.nodeCount } }
  }
  var committedPreparedNodeCount: Int { committedBatches.reduce(0) { $0+$1.mesh.preparedNodeCount } }
  private(set) var preparedCommittedPointCount = 0
  private(set) var queriedCommittedPointCount = 0
  private(set) var committedIndexVisitCount = 0

  private static let framesInFlight = 3
  /// A retained surface submits one GPU frame at a time beside its shown frame.
  /// Preparation uses that same second slot, never a second full drawable pool.
  nonisolated static let spatialFramesInFlight = 2

  private let commandQueue: (any MTLCommandQueue)?
  private let baselinePipelineState: (any MTLRenderPipelineState)?
  private let inkPipelineState: (any MTLRenderPipelineState)?
  private let eraserPipelineState: (any MTLRenderPipelineState)?
  private let textureLoader: MTKTextureLoader?
  private let resources: SceneRenderResources
  private let inFlightSemaphore = DispatchSemaphore(
    value: InkCanvasView.framesInFlight
  )

  /// The coordinate basis of the installed drawable. A physical scene mount
  /// projects these already presented pixels while another basis is prepared.
  private(set) var spatialCamera: SpatialCamera?
  private(set) var spatialViewport = SpatialPoint(x: 1, y: 1)
  private struct CommittedViewport: Equatable {
    let camera: SpatialCamera?
    let viewport: SpatialPoint
    let size: CGSize
    let crop: CGRect?
    let pixels: CGSize
    let scale: Double?
  }
  private var committedViewport: (key: CommittedViewport, visible: [(Int,Range<Int>)])?
  private var committedBatches: [CommittedBatch] = [] { didSet { committedViewport = nil } }
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
  private var material: InkMaterialRenderer?
  var materialUploadedNodeCount: Int { material?.uploadedNodes ?? 0 }
  private var pageDrawing: PageInkDrawing?
  private var drawingIsPreparing = false
  private var pageRevision: UInt64 = 0
  private var installedPageRevision: UInt64?
  private var pendingPageRevision: UInt64?
  private var pageMeshTask: Task<Void, Never>?
  private var pageCommit: UInt64 = 0
  private(set) var pageMeshBuildCount = 0
  private var baselineTexture: (any MTLTexture)?
  private var baselineReservation: RasterReservation?
  private var baselinePNG: Data?
  private(set) var pageRenderRegion: CGRect?
  private var pageSourceSize = CGSize.zero
  private var pageDrawableReservation: RasterReservation?
  private var pageAdmittedSize = CGSize.zero
  private var pageMultisample: (any MTLTexture)?

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
      count + batch.buffers.values.reduce(0) { $0 + $1.reservation.byteCount }
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

  var committedSourceNodeCount: Int {
    committedBatches.reduce(0) { $0 + $1.mesh.sourceNodeCount }
  }

  var committedEraserSourceNodeCount: Int {
    committedBatches.reduce(0) { count, batch in
      count + (batch.operation == .erase ? batch.mesh.sourceNodeCount : 0)
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
    baselinePipelineState = gpu.baseline
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

  isolated deinit { pageMeshTask?.cancel() }

  #if os(iOS)
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if let screen = window?.windowScene?.screen { preferredFramesPerSecond = screen.maximumFramesPerSecond }
    mounted()
  }
  override func layoutSubviews() { super.layoutSubviews(); schedulePageMeshIfNeeded() }
  #else
  override var isOpaque: Bool { false }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); mounted() }
  override func layout() { super.layout(); schedulePageMeshIfNeeded() }
  #endif

  private func mounted() {
    guard window != nil else {
      // UIKit can retain a culled canvas beyond the end of its visible use.
      // Stop its timer even when no drawable arrives to finish the last draw.
      isPaused = true
      cancelPendingPageMesh()
      if spatialHandoffRetains == 0 {
        releaseDrawables()
        pageDrawableReservation = nil; pageMultisample = nil
        releaseGeometryBuffers()
        spatialTarget?.detach(); spatialTarget = nil
      }
      return
    }
    if spatialHandoffRetains > 0, isStableFramePresented, hasRevealedFirstFrame,
      activeInkStroke == nil, activeEraserStroke == nil {
      // Moving the retained layer out of its preparation window does not
      // invalidate its presented pixels. Its native owner supplies the pose;
      // a second drawable here races the first camera sample after mounting.
      isPaused = true
    } else {
      requestFrame()
    }
    schedulePageMeshIfNeeded()
  }

  /// Page hosts keep canonical input bounds. Only the visible Metal child is
  /// cropped; its backing follows the actual ancestor projection into pixels.
  func projectPage(region: CGRect, sourceSize: CGSize, pixelDensity: CGFloat) {
    guard spatialDrawableScale == nil, !region.isEmpty, !region.isNull else { return }
    let pixels = CGSize(width: ceil(region.width * pixelDensity), height: ceil(region.height * pixelDensity))
    guard pixels.width.isFinite, pixels.height.isFinite,
      (1...16_384).contains(pixels.width), (1...16_384).contains(pixels.height) else { return }
    guard region != pageRenderRegion || drawableSize != pixels || pageSourceSize != sourceSize else { return }
    pageRenderRegion = region; pageSourceSize = sourceSize
    autoResizeDrawable = false
    frame = region
    drawableSize = pixels
    beginStableContentUpdate()
    requestFrame()
  }

  func updateMaterial(_ content: NotebookInkMaterialView.Content) {
    guard !spatialHandoffIsStopping else { return }
    if material == nil { material = InkMaterialRenderer() }
    guard material!.update(content) else { return }
    clearColor = material!.isMask ? .init(red:1,green:1,blue:1,alpha:1) : .init(red:0,green:0,blue:0,alpha:0)
    beginStableContentUpdate()
    requestFrame()
  }

  private func admitPageDrawable(samples: Int) -> Bool {
    guard pageRenderRegion != nil else { return true }
    if pageDrawableReservation != nil, pageAdmittedSize == drawableSize { return true }
    guard let device else { return false }
    let width = Int(drawableSize.width), height = Int(drawableSize.height)
    let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat,
      width: width, height: height, mipmapped: false)
    color.storageMode = .private; color.usage = .renderTarget
    let drawableBytes = max(device.heapTextureSizeAndAlign(descriptor: color).size,
      ((width * 4 + 255) / 256) * 256 * height)
    let msaa = MTLTextureDescriptor()
    msaa.textureType = .type2DMultisample; msaa.pixelFormat = colorPixelFormat
    msaa.width = width; msaa.height = height; msaa.sampleCount = samples
    msaa.usage = .renderTarget
    msaa.storageMode = device.supportsFamily(.apple1) ? .memoryless : .private
    let attachmentBytes = samples > 1 && msaa.storageMode != .memoryless
      ? device.heapTextureSizeAndAlign(descriptor: msaa).size : 0
    guard let reservation = resources.reserveDerivedBytes(drawableBytes * Self.framesInFlight + attachmentBytes,
      priority: .input, owner: physicalAdmission) else { renderFailure = .resourceLimit; return false }
    let attachment = samples > 1 ? device.makeTexture(descriptor: msaa) : nil
    guard samples == 1 || attachment != nil else { renderFailure = .resourceLimit; return false }
    pageDrawableReservation = reservation; pageMultisample = attachment; pageAdmittedSize = drawableSize
    return true
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
    cancelPendingPageMesh()
    material = nil
    pageDrawableReservation = nil; pageMultisample = nil
    pageDrawing = nil; baselineTexture = nil; baselinePNG = nil; baselineReservation = nil
    installedPageRevision = nil; pendingPageRevision = nil
    committedBatches.removeAll(); spatialActionBase = nil
    discardActiveAction()
    installedSpatialSource = nil; spatialSourceGeneration &+= 1
    spatialStagingID = nil
    visibleCommittedVertexCount = 0; visibleCommittedChunkCount = 0
    drawnTiles = nil
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
    pageMeshTask?.cancel(); pageMeshTask = nil
    material = nil
    pageDrawableReservation = nil; pageMultisample = nil
    pageDrawing = nil; baselineTexture = nil; baselinePNG = nil; baselineReservation = nil
    installedPageRevision = nil; pendingPageRevision = nil
    committedBatches = mesh.batches.map(CommittedBatch.init)
    discardActiveAction()
    requestFrame()
  }

  /// Source and geometry are installed by the same physical owner. This is a
  /// source receipt, not a GPU-presented or visible-pixels acknowledgement.
  func installSpatialSource(_ journal: SpatialInkJournal?, on surface: SurfaceID, suppressedInkIDs: Set<UUID> = []) {
    installedSpatialSource = journal.map { .init(surface: surface, journal: $0, suppressedInkIDs: suppressedInkIDs) }
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
    cancelPendingPageMesh()
    pageRevision &+= 1
    pageDrawing = drawing
    drawingIsPreparing = false
    beginStableContentUpdate()
    baselineTexture = nil; baselinePNG = nil; baselineReservation = nil
    installedPageRevision = nil
    // Capture reusable action meshes before clearing the old page's display.
    // Shared IDs are validated off-main, so undo/sync reuse surviving history
    // while a different physical page never displays its predecessor.
    schedulePageMeshIfNeeded()
    committedBatches.removeAll(keepingCapacity: true)
    discardActiveAction()
  }

  /// Durable delivery changes source ownership, not the pixels of a measured
  /// contact. Retain its mesh/buffers; prepare only newly received actions.
  func settle(_ drawing: PageInkDrawing) {
    cancelPendingPageMesh()
    pageRevision &+= 1
    pageDrawing = drawing
    drawingIsPreparing = false
    beginStableContentUpdate()
    schedulePageMeshIfNeeded()
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
      activeInkStroke = stroke
      activeEraserStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
      activeRenderID = UUID()
    }
    requestFrame()
  }

  /// Composites the measured destination-out brush over the stable page.
  func displayActiveEraser(_ stroke: ActiveEraserStroke) {
    if activeEraserStroke !== stroke {
      beginStableContentUpdate()
      activeEraserStroke = stroke
      activeInkStroke = nil
      builtActiveIdentity = nil
      builtActiveRevision = nil
      activeRenderID = UUID()
    }
    requestFrame()
  }

  /// Finish only the measured tail of the live mesh. Predictions never enter
  /// the durable batch, and a long contact is not rebuilt at Pencil-up.
  func commitActiveStroke(_ action: PageInkAction? = nil) { guard activeInkStroke != nil else { return }; commitMeasuredMesh(action) }
  func commitActiveEraser(_ action: PageInkAction? = nil) { guard activeEraserStroke != nil else { return }; commitMeasuredMesh(action) }
  func commitActiveSpatialAction() { commitMeasuredMesh() }

  private func commitMeasuredMesh(_ action: PageInkAction? = nil) {
    let identity: ObjectIdentifier
    let measured: InkSampleRelations.Contact
    let projection: InkSampleProjection
    let color: SIMD4<Float>
    let operation: RenderOperation
    let changed: Int
    if let stroke = activeInkStroke {
      identity = ObjectIdentifier(stroke); measured=stroke.measured;projection=stroke.projection
      let value = stroke.style.color.components
      color = .init(Float(value.red), Float(value.green), Float(value.blue), 1)
      operation = .ink; changed = stroke.consumeChangedStart()
    } else if let stroke = activeEraserStroke {
      identity = ObjectIdentifier(stroke); measured=stroke.measured;projection=stroke.projection
      color = .init(1, 1, 1, 1); operation = .erase; changed = stroke.consumeChangedStart()
    } else { return }
    if builtActiveIdentity != identity { activeMesh = IncrementalInkMesh(eraser:operation == .erase) }
    activeMesh.update(measured:measured,changedFrom:builtActiveIdentity == identity ? changed : 0,color:color,projection:projection)
    appendCommitted(activeMesh, operation: operation, action: action)
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
    schedulePageMeshIfNeeded()
    requestFrame()
  }

  func draw(in view: MTKView) {
    guard window != nil, !spatialHandoffIsStopping, spatialStagingID == nil else { isPaused = true; return }
    if spatialDrawableScale != nil, submittedFrameCount > 0 || submittedPresentationCount > 0 { return }
    if presentEmptyContentIfReady() { return }
    let samples = device?.supportsTextureSampleCount(4) == true ? 4 : 1
    guard admitSpatialDrawable(samples: samples), admitPageDrawable(samples: samples) else { return }
    // Page crops and retained scene canvases own their MSAA attachment.
    // Apple GPUs keep it in tile memory; do not allocate another implicit copy.
    sampleCount = spatialDrawableScale == nil && pageRenderRegion == nil ? samples : 1
    guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }
    var mustSignal = true
    defer {
      if mustSignal {
        inFlightSemaphore.signal()
      }
    }

    guard let visible = prepareCommittedBuffers() else { renderFailure = .resourceLimit; return }
    let active = prepareActiveBuffer(in: frameSlot)
    if (activeInkStroke != nil || activeEraserStroke != nil) && !activeMesh.nodes.isEmpty
      && active == nil
    {
      renderFailure = .resourceLimit; return
    }
    guard let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    var passes:
      [(MTLRenderPassDescriptor, any CAMetalDrawable, MTLViewport?, CGRect?, [(Int, Range<Int>)])] = []
    var signatures: [TileSignature] = []
    if let target = spatialTarget {
      let previous = drawnTiles?.target == ObjectIdentifier(target) ? drawnTiles?.signatures : nil
      for (index, tile) in target.tiles.enumerated() {
        let clip = target.logicalRect(index)
        let tileVisible = visibleChunks(in: clip)
        let signature = tileSignature(visible: tileVisible, clip: clip)
        signatures.append(signature)
        if !needsRevealedFrame, let previous, index < previous.count, previous[index] == signature {
          continue
        }
        guard let drawable = tile.layer.nextDrawable(),
          drawable.texture.allocatedSize <= tile.drawableByteCeiling
        else {
          renderFailure = .resourceLimit; return
        }
        passes.append(
          (
            spatialRenderPass(target: tile, drawable: drawable), drawable, target.viewport(index),
            clip, tileVisible
          ))
      }
    } else {
      guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
      if let pageMultisample {
        pass.colorAttachments[0].texture = pageMultisample
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].storeAction = .multisampleResolve
      }
      passes.append((pass, drawable, nil, nil, visible))
    }
    lastRenderedTileCount = passes.count
    guard !passes.isEmpty else {
      if activeInkStroke == nil, activeEraserStroke == nil, pageGeometryIsReady {
        isPaused = true
        let revision = stableContentRevision
        Task { @MainActor [weak self] in
          guard let self, stableContentRevision == revision, spatialStagingID == nil, window != nil,
            activeInkStroke == nil, activeEraserStroke == nil, pageGeometryIsReady,
            !spatialHandoffIsStopping
          else { return }
          presentedStableContentRevision = revision; onRenderReadinessChange?(true)
        }
      }
      return
    }
    drawableRequestCount += 1
    submittedTileCount += passes.count
    needsRevealedFrame = false
    var materialReservations: [RasterReservation] = []
    for (descriptor, _, viewport, clip, tileVisible) in passes {
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].clearColor = clearColor
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
      if let viewport { encoder.setViewport(viewport) }
      if let baselineTexture, let baselinePipelineState {
        encoder.label = "Imported Notebook Ink Baseline"
        encoder.setRenderPipelineState(baselinePipelineState)
        var textureRect = SIMD4<Float>(0, 0, 1, 1)
        if let crop = pageRenderRegion, pageSourceSize.width > 0, pageSourceSize.height > 0 {
          textureRect = .init(Float(crop.minX/pageSourceSize.width), Float(crop.minY/pageSourceSize.height),
            Float(crop.width/pageSourceSize.width), Float(crop.height/pageSourceSize.height))
        }
        encoder.setVertexBytes(&textureRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(baselineTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      }
      encodeSpatial(
        batches: committedBatches, visible: tileVisible, active: active,
        camera: spatialCamera, viewport: spatialViewport, size: bounds.size, clip: clip, encoder: encoder)
      if let material, let device {
        do {
          materialReservations += try material.encode(
            region:pageRenderRegion ?? CGRect(origin:.zero,size:bounds.size),
            sourceSize:pageSourceSize == .zero ? bounds.size : pageSourceSize,pixels:drawableSize,
            device:device,resources:resources,owner:physicalAdmission,encoder:encoder)
        } catch {
          encoder.endEncoding(); renderFailure = .resourceLimit; return
        }
      }
      encoder.endEncoding()
    }
    presentsWithTransaction = false
    for tile in spatialTarget?.tiles ?? [] { tile.layer.presentsWithTransaction = false }
    for (_, drawable, _, _, _) in passes { commandBuffer.present(drawable) }
    let presentedRevision: UInt64? =
      activeInkStroke == nil
        && activeEraserStroke == nil
        && pageGeometryIsReady
      ? stableContentRevision : nil
    let submittedRevision = stableContentRevision
    let heldGeometry = materialReservations + visible.compactMap { committedBatches[$0.0].buffers[$0.1]?.reservation }
      + (activeBufferReservations[frameSlot].map { [$0] } ?? [])
      + (baselineReservation.map { [$0] } ?? [])
      + (pageDrawableReservation.map { [$0] } ?? [])
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
        if !completed { drawnTiles = nil }
        guard completed, !spatialHandoffIsStopping, window != nil,
          stableContentRevision == submittedRevision else { return }
        renderFailure = nil
        if !hasRevealedFirstFrame {
          hasRevealedFirstFrame = true
          needsRevealedFrame = true
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
    if let target = spatialTarget { drawnTiles = (ObjectIdentifier(target), signatures) }
    commandBuffer.commit()
    mustSignal = false
    frameSlot = (frameSlot + 1) % Self.framesInFlight

    if activeInkStroke == nil, activeEraserStroke == nil { isPaused = true }
  }

  private func visibleChunks(in clip: CGRect) -> [(Int, Range<Int>)] {
    // The viewport query already selected and prepared resident chunks. Tiles
    // filter those descriptors; they must not repeat source-range disclosure.
    committedBatches.enumerated().flatMap { b, batch in
      let transform=batch.mesh.projection.transform(camera:spatialCamera,viewport:spatialViewport)
      return batch.buffers.keys.sorted { $0.lowerBound < $1.lowerBound }.filter {
        batch.buffers[$0]!.isVisible && batch.buffers[$0]!.geometry.chunk.descriptor.intersects(viewport:clip,transform:transform)
      }.map { (b,$0) }
    }
  }

  private func tileSignature(visible: [(Int, Range<Int>)], clip: CGRect) -> TileSignature {
    var tokens: [TileToken] = []
    for (b, c) in visible {
      let batch = committedBatches[b],
        transform = batch.mesh.projection.transform(
          camera: spatialCamera, viewport: spatialViewport)
      guard let chunk=batch.buffers[c]?.geometry.chunk.descriptor,
        chunk.intersects(viewport:clip,transform:transform) else { continue }
      tokens.append(
        .init(
          source: batch.renderID, chunk: c, revision: 0, level: batch.buffers[c]?.level ?? -1,
          transform: transform))
    }
    for (c, chunk) in activeMesh.chunks.enumerated()
    where chunk.intersects(viewport: clip, transform: .init(1, 1, 0, 0)) {
      tokens.append(
        .init(
          source: activeRenderID, chunk: c..<(c+1), revision: activeMesh.chunkRevisions[c], level: -1,
          transform: .init(1, 1, 0, 0)))
    }
    return .init(tokens: tokens, baseline: baselineTexture.map { ObjectIdentifier($0) })
  }

  private func encodeSpatial(batches: [CommittedBatch], visible: [(Int, Range<Int>)],
    active: (buffer: any MTLBuffer, operation: RenderOperation)?, camera: SpatialCamera?,
    viewport: SpatialPoint, size: CGSize, clip: CGRect? = nil, encoder: any MTLRenderCommandEncoder) {
    guard inkPipelineState != nil, eraserPipelineState != nil else { return }
    encoder.label = "Notebook Ink"
    var viewportSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
    encoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    for (batchIndex, chunkIndex) in visible {
      let batch = batches[batchIndex]
      var transform = batch.mesh.projection.transform(camera: camera, viewport: viewport)
      if camera == nil, let crop = pageRenderRegion {
        transform.z -= Float(crop.minX); transform.w -= Float(crop.minY)
      }
      guard let prepared=batch.buffers[chunkIndex] else { continue }
      let chunk=prepared.geometry.chunk.descriptor
      if let clip, !chunk.intersects(viewport:clip,transform:transform) { continue }
      var affine = InkAffine(transform)
      encoder.setVertexBytes(&affine, length: MemoryLayout<InkAffine>.stride, index: 2)
      draw(
        buffer:prepared.buffer,
        nodeCount:prepared.nodeCount,
        flags: chunk.flags, color: chunk.color, operation: batch.operation, with: encoder)
    }
    if let active {
      var identity = InkAffine()
      if camera == nil, let crop = pageRenderRegion { identity.x.z = -Float(crop.minX); identity.y.z = -Float(crop.minY) }
      encoder.setVertexBytes(&identity, length: MemoryLayout<InkAffine>.stride, index: 2)
      for chunk in activeMesh.chunks {
        if let clip, !chunk.intersects(viewport: clip, transform: .init(1, 1, 0, 0)) { continue }
        draw(
          buffer: active.buffer, nodeCount: chunk.nodes.count, flags: chunk.flags,
          color: chunk.color,
          operation: active.operation, offset: chunk.nodes.lowerBound * MemoryLayout<Node>.stride,
          with: encoder)
      }
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
    fileprivate let camera: SpatialCamera?
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
      layout: SpatialTargetLayout, viewport: SpatialPoint, camera: SpatialCamera?,
      target: SpatialTarget?, drawables: [any CAMetalDrawable]) {
      self.id = id; self.canvas = canvas; self.batches = batches; self.drawables = drawables
      self.replacesMesh = replacesMesh; self.layout = layout; self.viewport = viewport; self.camera = camera; self.target = target
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
  func prepareSpatialFrame(_ mesh: SpatialInkMesh?, size: SpatialPoint, displayScale: Double,
    camera requestedCamera: SpatialCamera? = nil) async throws -> PreparedSpatialFrame {
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
    let viewport = size, camera = requestedCamera ?? spatialCamera
    var batches = mesh?.batches.map(CommittedBatch.init) ?? committedBatches
    let visible = try prepareBuffers(
      in: &batches, camera: camera, viewport: viewport, size: layout.size,
      pixelScale: Float(displayScale),rasterSize:layout.pixelSize)
    if visible.isEmpty {
      let result = PreparedSpatialFrame(id: id, canvas: self, batches: batches, replacesMesh: mesh != nil,
        layout: layout, viewport: viewport, camera: camera, target: nil, drawables: [])
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
      layout: layout, viewport: viewport, camera: camera, target: target, drawables: drawables)
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
  func installSpatialFrame(_ frame: PreparedSpatialFrame, journal: SpatialInkJournal, surface: SurfaceID, suppressedInkIDs: Set<UUID> = []) {
    precondition(frame.canvas === self && frame.isValid)
    frame.installed = true
    spatialSourceGeneration &+= 1; stableContentRevision &+= 1
    if frame.replacesMesh { spatialMeshInstallCount += 1 }
    cancelPendingPageMesh()
    material = nil
    pageDrawableReservation = nil; pageMultisample = nil
    pageDrawing = nil; baselineTexture = nil; baselinePNG = nil; baselineReservation = nil; drawingIsPreparing = false
    installedPageRevision = nil; pendingPageRevision = nil
    committedBatches = frame.batches; drawnTiles = nil; discardActiveAction()
    installedSpatialSource = .init(surface: surface, journal: journal, suppressedInkIDs: suppressedInkIDs)
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
    spatialCamera = frame.camera; spatialViewport = frame.viewport; spatialDrawableScale = frame.layout.displayScale
    installSpatialTarget(frame.target)
    needsRevealedFrame = false
    if let target = frame.target {
      drawnTiles = (
        ObjectIdentifier(target),
        target.tiles.indices.map { index in
          let clip = target.logicalRect(index)
          return tileSignature(visible: visibleChunks(in: clip), clip: clip)
        }
      )
    }
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

  var pageGeometryIsReady: Bool {
    !drawingIsPreparing && (pageDrawing == nil || installedPageRevision == pageRevision)
  }

  private func cancelPendingPageMesh() {
    // An unmount may immediately remount the same source. Its cancelled
    // continuation must not clear or publish the replacement preparation.
    if pendingPageRevision != nil { pageRevision &+= 1 }
    pageMeshTask?.cancel(); pageMeshTask = nil
    pendingPageRevision = nil
  }

  private func schedulePageMeshIfNeeded() {
    guard let drawing = pageDrawing, installedPageRevision != pageRevision,
      pendingPageRevision != pageRevision else { return }
    let revision = pageRevision, commit = pageCommit
    pendingPageRevision = revision
    // The source arrays and mesh buffers are immutable COW values. MainActor
    // neither walks old samples nor copies their vertices at Pencil-up.
    // Short contacts already fit one upload chunk. Long accepted contacts
    // release their full incremental geometry after one off-thread source
    // preparation; canonical batches (pageCommit == 0) remain reusable.
    let oldBatches = committedBatches.filter {
      guard let action=$0.pageAction else { return false }
      return $0.pageCommit == 0 || action.samples.count <= InkRenderGeometry.maximumSegments
    }
    let old = oldBatches.map { PageInkMesh.Entry(action:$0.pageAction!,mesh:$0.mesh,reusedIndex:nil) }
    let worker = Task.detached(priority: .userInitiated) { try PageInkMesh.prepare(drawing, reusing: old) }
    pageMeshTask = Task { [weak self] in
      do {
        let mesh = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard let self, acceptsPageMesh(revision) else { return }
        try await prepareBaseline(drawing.baselinePNG, revision: revision)
        guard acceptsPageMesh(revision) else { return }
        var batches = mesh.entries.map { entry in
          var batch = entry.reusedIndex.map { oldBatches[$0] } ?? CommittedBatch(entry.mesh)
          batch.pageAction = entry.action
          return batch
        }
        // Preparation may finish between two contacts. A newer measured tail
        // and the currently active contact are never replaced by an older cut.
        let ids = Set(drawing.actions.map(\.id))
        batches += committedBatches.filter { $0.pageCommit > commit && ($0.pageAction.map { !ids.contains($0.id) } ?? true) }
        committedBatches = batches
        pageMeshBuildCount += mesh.builtActionCount
        installedPageRevision = revision; pendingPageRevision = nil; pageMeshTask = nil
        requestFrame()
      } catch {
        guard let self, pendingPageRevision == revision else { return }
        pendingPageRevision = nil; pageMeshTask = nil
        if !(error is CancellationError) { renderFailure = (error as? SceneRenderError) ?? .snapshotPending("page_ink_geometry") }
      }
    }
  }

  private func acceptsPageMesh(_ revision: UInt64) -> Bool {
    !Task.isCancelled && !spatialHandoffIsStopping && pendingPageRevision == revision && pageRevision == revision
  }

  /// Only a genuinely imported image is a texture. New handwriting never
  /// replaces geometry with a flattened page image or a fixed 2x resolution.
  private func prepareBaseline(_ png: Data?, revision: UInt64) async throws {
    guard baselinePNG != png else { return }
    guard let png else { baselineTexture = nil; baselinePNG = nil; baselineReservation = nil; return }
    guard let textureLoader,
      let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 8192, height <= 8192,
      let allocation = resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 2)
    else { throw SceneRenderError.resourceLimit }
    let texture = try await textureLoader.newTexture(data: png,
      options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
    guard acceptsPageMesh(revision) else { throw CancellationError() }
    baselineTexture = texture; baselinePNG = png; baselineReservation = allocation
  }

  private func requestFrame() {
    if presentEmptyContentIfReady() { return }
    // Mesh/raster completions may arrive after culling. Preserve their ready
    // content, but only a mounted surface can resume display execution.
    isPaused = window == nil || spatialStagingID != nil || spatialHandoffIsStopping
  }

  @discardableResult
  private func presentEmptyContentIfReady() -> Bool {
    guard material == nil, !spatialHandoffIsStopping, spatialStagingID == nil, pageGeometryIsReady, baselineTexture == nil,
      activeInkStroke == nil, activeEraserStroke == nil,
      committedBatches.allSatisfy({ batch in
        if batch.mesh.isEmpty { return true }
        guard spatialDrawableScale != nil, bounds.width > 0, bounds.height > 0 else { return false }
        let transform = batch.mesh.projection.transform(camera: spatialCamera, viewport: spatialViewport)
        return batch.mesh.query(viewport:CGRect(origin:.zero,size:bounds.size).insetBy(dx:-1,dy:-1),affine:.init(transform)).chunks.isEmpty
      })
    else { return false }
    // Source ink elsewhere on this board is not a visible Metal allocation.
    // Keep its mesh; a later projection prepares the same chunks normally.
    for batch in committedBatches.indices {
      committedBatches[batch].buffers.removeAll(keepingCapacity: true)
    }
    visibleCommittedVertexCount = 0; visibleCommittedChunkCount = 0
    drawnTiles = nil
    isPaused = true
    if sampleCount != 1 { sampleCount = 1 }
    releaseDrawables()
    pageDrawableReservation = nil; pageMultisample = nil
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
      guard let self, !spatialHandoffIsStopping, stableContentRevision == revision, pageGeometryIsReady,
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
    material?.releaseBuffers()
    drawnTiles = nil
    for index in committedBatches.indices {
      committedBatches[index].buffers.removeAll(keepingCapacity: true)
    }
    releaseActiveBuffers()
  }

  private func prepareActiveBuffer(
    in slot: Int
  ) -> (buffer: any MTLBuffer, operation: RenderOperation)? {
    let identity: ObjectIdentifier
    let revision: UInt64
    let measured: InkSampleRelations.Contact
    let predicted: [SpatialInkSample]
    let projection: InkSampleProjection
    let color: SIMD4<Float>
    let operation: RenderOperation

    if let activeInkStroke {
      identity = ObjectIdentifier(activeInkStroke)
      revision = activeInkStroke.revision
      measured = activeInkStroke.measured
      predicted = activeInkStroke.predicted
      projection=activeInkStroke.projection
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
      measured = activeEraserStroke.measured
      predicted = []
      projection=activeEraserStroke.projection
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
        activeMesh = IncrementalInkMesh(eraser:operation == .erase)
        activeBufferDirtyStarts = Array(repeating: 0, count: Self.framesInFlight)
      }
      activeMesh.update(measured:measured,predicted:predicted,changedFrom:changed,color:color,projection:projection)
      for index in activeBufferDirtyStarts.indices {
        activeBufferDirtyStarts[index] = min(
          activeBufferDirtyStarts[index], activeMesh.rebuiltNodeStart)
      }
      builtActiveIdentity = identity
      builtActiveRevision = revision
    }
    guard !activeMesh.nodes.isEmpty else { return nil }

    let requiredLength = activeMesh.nodes.count * MemoryLayout<Node>.stride
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
    let start = min(activeBufferDirtyStarts[slot], activeMesh.nodes.count)
    let offset = start * MemoryLayout<Node>.stride
    let length = requiredLength - offset
    if length > 0 {
      activeMesh.nodes.withUnsafeBytes { bytes in
        if let base = bytes.baseAddress {
          buffer.contents().advanced(by: offset).copyMemory(from: base.advanced(by: offset), byteCount: length)
        }
      }
      activeUploadedByteCount += length
    }
    activeBufferDirtyStarts[slot] = activeMesh.nodes.count
    return (buffer, operation)
  }

  private func appendCommitted(
    _ active: IncrementalInkMesh,
    operation: RenderOperation,
    action: PageInkAction?
  ) {
    guard !active.nodes.isEmpty else { return }
    let projection = spatialCamera.map { SpatialInkMesh.Projection.screen($0, spatialViewport) } ?? .local
    // The contact already indexed its mutable tail on display frames. Sealing
    // it retains those arrays; it neither rescans nor copies the older history.
    var batch = CommittedBatch(.init(tool: operation == .ink ? .pen : .eraser,
        nodes: active.nodes, chunks: active.committedChunks, projection: projection))
    pageCommit &+= 1
    batch.pageAction = action; batch.pageCommit = pageCommit
    committedBatches.append(batch)
  }

  private func prepareCommittedBuffers() -> [(Int, Range<Int>)]? {
    let key=CommittedViewport(camera:spatialCamera,viewport:spatialViewport,size:bounds.size,
      crop:pageRenderRegion,pixels:spatialTarget?.layout.pixelSize ?? drawableSize,scale:spatialDrawableScale)
    if let prepared=committedViewport,prepared.key == key { return prepared.visible }
    guard let visible = try? prepareBuffers(in: &committedBatches,
      camera: spatialCamera, viewport: spatialViewport, size: bounds.size) else { return nil }
    visibleCommittedVertexCount = visible.reduce(0) {
      $0
        + InkRenderGeometry.vertexCount(
          nodes: committedBatches[$1.0].buffers[$1.1]!.nodeCount,
          flags: committedBatches[$1.0].buffers[$1.1]!.geometry.chunk.descriptor.flags)
    }
    visibleCommittedChunkCount = visible.count
    // Mutating batches (including resource eviction) invalidates this one
    // selection. Active samples alone never re-query the unchanged baseline.
    committedViewport=(key,visible)
    return visible
  }

  private func prepareBuffers(in batches: inout [CommittedBatch], camera: SpatialCamera?,
    viewport: SpatialPoint, size: CGSize, pixelScale: Float? = nil, rasterSize: CGSize? = nil
  ) throws -> [(Int, Range<Int>)] {
    var visible: [(Int, Range<Int>)] = []
    let viewportRect = camera == nil ? (pageRenderRegion ?? CGRect(origin: .zero, size: size)) : CGRect(origin: .zero, size: size)
    let pixelsPerPoint =
      pixelScale ?? Float(spatialDrawableScale ?? Double(drawableSize.width / max(bounds.width, 1)))
    let grid=InkRasterRenderer.shared.sampleGrid(viewport:size,
      pixels:rasterSize ?? spatialTarget?.layout.pixelSize ?? drawableSize)
    for batchIndex in batches.indices {
      let mesh = batches[batchIndex].mesh
      let transform = mesh.projection.transform(camera: camera, viewport: viewport)
      var rasterTransform=transform
      if camera == nil,let crop=pageRenderRegion {
        rasterTransform.z -= Float(crop.minX);rasterTransform.w -= Float(crop.minY)
      }
      let affine=InkAffine(rasterTransform)
      let query=mesh.query(viewport:viewportRect.insetBy(dx:-1,dy:-1),affine:.init(transform),
        detail:.init(pixelsPerUnit:affine.maximumStretch*pixelsPerPoint,minimumPixelsPerUnit:affine.minimumStretch*pixelsPerPoint),
        admitting:grid.map { grid in { grid.mayCover($0,affine:affine) } })
      committedIndexVisitCount += query.cost.visitedNodes
      queriedCommittedPointCount += query.cost.decodedSamples
      let selected=query.chunks
      let selectedIDs = Set(selected)
      // A sample-free overview must not discard the already admitted detail
      // of its last nonempty view, then decode it again on every zoom toggle.
      // Keep that one view in the existing charged pool, never draw it. A new
      // nonempty selection or geometric exit retires it normally.
      for chunkIndex in batches[batchIndex].buffers.keys {
        if selectedIDs.contains(chunkIndex) { batches[batchIndex].buffers[chunkIndex]?.isVisible=true;continue }
        let bounds=batches[batchIndex].buffers[chunkIndex]!.geometry.chunk.descriptor.bounds
        if selected.isEmpty,grid?.mayCover(bounds,affine:affine) == false,
          InkAffine(transform).bounds(bounds).intersects(viewportRect.insetBy(dx:-1,dy:-1)) {
          batches[batchIndex].buffers[chunkIndex]?.isVisible=false
        } else { batches[batchIndex].buffers[chunkIndex] = nil }
      }
      visible.append(contentsOf: selected.map { (batchIndex, $0) })
    }
    for (batchIndex, chunkIndex) in visible {
      let mesh=batches[batchIndex].mesh
      let geometry: PreparedGeometry
      if let retained=batches[batchIndex].buffers[chunkIndex]?.geometry { geometry=retained }
      else {
        let prepared=mesh.prepareChunk(chunkIndex)
        preparedCommittedPointCount += prepared.decodedPoints
        guard let reservation=resources.reserveDerivedBytes(prepared.chunk.byteCount,
          priority:physicalAdmission?.allocationPriority ?? .input,owner:physicalAdmission) else { throw SceneRenderError.resourceLimit }
        geometry=PreparedGeometry(prepared.chunk,reservation:reservation)
      }
      let transform=mesh.projection.transform(camera:camera,viewport:viewport)
      let level=InkRenderGeometry.level(geometry.chunk.descriptor.levels,
        pixelsPerUnit:max(abs(transform.x),abs(transform.y))*pixelsPerPoint,
        minimumPixelsPerUnit:min(abs(transform.x),abs(transform.y))*pixelsPerPoint)
      if batches[batchIndex].buffers[chunkIndex]?.level == level { continue }
      let selected=geometry.chunk.selected(level:level)
      guard let device,
        let reservation = resources.reserveDerivedBytes(
          selected.count * MemoryLayout<Node>.stride,
          priority: physicalAdmission?.allocationPriority ?? .input, owner: physicalAdmission),
        let buffer = selected.withUnsafeBytes({ bytes in
          device.makeBuffer(
            bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        })
      else { throw SceneRenderError.resourceLimit }
      buffer.label = "Visible compact ink nodes"
      batches[batchIndex].buffers[chunkIndex] = .init(
        geometry:geometry,buffer:buffer,reservation:reservation,nodeCount:selected.count,level:level)
    }
    return visible
  }

  private func draw(
    buffer: (any MTLBuffer)?, nodeCount: Int, flags: UInt32, color: SIMD4<Float>,
    operation: RenderOperation, offset: Int = 0, with encoder: any MTLRenderCommandEncoder
  ) {
    guard let buffer, nodeCount > 0,
      let pipeline = operation == .ink ? inkPipelineState : eraserPipelineState
    else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(buffer, offset: offset, index: 0)
    var primitive = InkPrimitive(count: UInt32(nodeCount), flags: flags, color: color)
    encoder.setVertexBytes(&primitive, length: MemoryLayout<InkPrimitive>.stride, index: 3)
    InkRasterRenderer.shared.connectivity?.draw(nodes: nodeCount, flags: flags, encoder: encoder)
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

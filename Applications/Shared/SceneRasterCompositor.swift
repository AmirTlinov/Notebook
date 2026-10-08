import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers
import SwiftUI

/// A composition owns one accounted output buffer and borrows one source at a
/// time. It never retains the archive's decoded images as a batch. The caller
/// keeps the physical source versions and decides whether publication is current.
@MainActor
final class SceneRasterCompositor {
  private let reservation: RasterReservation
  private let buffer: CompositionPixels
  private let resources: SceneRenderResources
  private let priority: SceneAllocationPriority
  let scale: Double
  private let size: CGSize
  private let permitsPreparation: @MainActor () -> Bool
  private var isFinished = false
  private var transfersReservation = false
  private var recordedDiagnostics: [RenderDiagnostic] = []
  private var omittedDiagnostics = 0
  var diagnostics: [RenderDiagnostic] {
    guard omittedDiagnostics > 0 else { return recordedDiagnostics }
    return recordedDiagnostics + [.init(kind: "diagnostics_truncated",
      message: "Ещё сообщений исполнения: \(omittedDiagnostics)")]
  }
  func recordDiagnostics(_ values: [RenderDiagnostic]) {
    guard !isFinished else { return }
    for value in values {
      if recordedDiagnostics.count < 255 { recordedDiagnostics.append(value) }
      else { omittedDiagnostics += 1 }
    }
  }


  static func create(size: CGSize, scale: Double, resources: SceneRenderResources,
    priority: SceneAllocationPriority = .passive,
    permitsPreparation: @escaping @MainActor () -> Bool = { true }) async throws -> SceneRasterCompositor {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
      size.width > 0, size.height > 0, size.width * scale <= 8192, size.height * scale <= 8192
    else { throw SceneRenderError.resourceLimit }
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
    guard let reservation = resources.reserveRaster(pixelWidth: width, pixelHeight: height, priority: priority) else {
      throw SceneRenderError.resourceLimit
    }
    do {
      let buffer = try await CompositionPixels.create(size: size, width: width, height: height, scale: scale)
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      return Self(reservation: reservation, buffer: buffer, resources: resources, priority: priority,
        size: size, scale: scale, permitsPreparation: permitsPreparation)
    } catch { reservation.release(); throw error }
  }

  private init(reservation: RasterReservation, buffer: CompositionPixels,
    resources: SceneRenderResources, priority: SceneAllocationPriority,
    size: CGSize, scale: Double, permitsPreparation: @escaping @MainActor () -> Bool) {
    self.reservation = reservation; self.buffer = buffer; self.resources = resources
    self.priority = priority
    self.size = size; self.scale = scale; self.permitsPreparation = permitsPreparation
  }

  func drawPNG(_ data: Data, in frame: CGRect) async throws {
    try checkPreparation()
    try await buffer.drawPNG(data, in: frame)
    try checkPreparation()
  }

  /// The caller keeps the source allocation charged until this copy completes.
  func drawImage(_ image: CGImage, in frame: CGRect) async throws {
    try checkPreparation()
    try await buffer.draw(image, in: frame)
    try checkPreparation()
  }

  /// Plain paper needs no view graph or temporary raster. Paint into this
  /// composition's admitted destination using the native paper geometry.
  func drawPaper(size: CGSize, in frame: CGRect) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    try await buffer.drawPaper(size: size, in: frame)
    try checkPreparation()
  }

  /// Use the retained entry, not a cache lookup after an asynchronous boundary.
  /// A newer capture of the same program cannot replace the borrowed pixels.
  func draw(_ raster: RasterLease, in frame: CGRect, erasures: [InkElementErasure] = [], elementFrame: CGRect? = nil,
    presentation: NotebookElementPresentation? = nil) async throws {
    defer { withExtendedLifetime(raster) {} }
    try checkPreparation()
    guard !raster.isReleased else { throw SceneRenderError.snapshotPending("released_source") }
    #if os(iOS)
      let image = raster.image.cgImage
    #else
      let image = raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #endif
    guard let image else { throw SceneRenderError.snapshotPending("source_pixels") }
    try await drawSource(image, source: raster.source, in: frame, erasures: erasures,
      elementFrame: elementFrame, presentation: presentation)
  }

  /// An accepted turn borrows these exact pixels without publishing a cache
  /// entry. Geometry and erased regions use the same painter as stored rasters.
  func draw(_ cut: SceneRasterCut, in frame: CGRect, erasures: [InkElementErasure] = [], elementFrame: CGRect? = nil,
    presentation: NotebookElementPresentation? = nil) async throws {
    defer { withExtendedLifetime(cut) {} }
    try checkPreparation()
    try await drawSource(cut.image, source: cut.source, in: frame, erasures: erasures,
      elementFrame: elementFrame, presentation: presentation)
  }

  private func drawSource(_ image: CGImage, source: SceneRasterSource, in frame: CGRect,
    erasures: [InkElementErasure], elementFrame: CGRect?, presentation: NotebookElementPresentation?) async throws {
    if let presentation, presentation.requiresRasterTransform {
      let size=presentation.bodySize
      let crop=source.captureRegion.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }
        ?? CGRect(origin:.zero,size:size)
      let appearance=erasures.isEmpty ? nil : try await NotebookElementErasureCache.Input(graphic:nil,
        layout:nil,size:size,erasures:erasures).prepared()
      try await drawView(NotebookPlacedElement(presentation:presentation) {
        Image(decorative:image,scale:1).resizable().frame(width:crop.width,height:crop.height)
          .position(x:crop.midX,y:crop.midY).frame(width:size.width,height:size.height)
          .snapshotErased(by:erasures,appearance:appearance)
      },size:presentation.bounds.size,in:elementFrame ?? frame)
      return
    }
    if !erasures.isEmpty, let element = source.agentElement {
      let size = CGSize(width: element.frame.width, height: element.frame.height)
      let crop = source.captureRegion.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        ?? CGRect(origin: .zero, size: size)
      let appearance = try await NotebookElementErasureCache.Input(graphic: nil,
        layout: nil, size: size, erasures: erasures).prepared()
      try checkPreparation()
      try await drawView(Image(decorative: image, scale: 1).resizable()
        .frame(width: crop.width, height: crop.height)
        .position(x: crop.midX, y: crop.midY)
        .frame(width:size.width,height:size.height).snapshotErased(by:erasures,appearance:appearance),
        size: size, in: elementFrame ?? frame)
      return
    }
    try await buffer.draw(image, in: frame)
    try checkPreparation()
  }

  /// The board grid has no offscreen effects: each destination-aligned piece
  /// can be painted independently, unlike paper covers with shadows.
  func drawBoardGrid(camera: SpatialCamera, size: CGSize, in frame: CGRect) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    let left = Int(floor(visible.minX * scale)), top = Int(floor(visible.minY * scale))
    let right = Int(ceil(visible.maxX * scale)), bottom = Int(ceil(visible.maxY * scale))
    for y in stride(from: top, to: bottom, by: CompositionTile.pixelSize) {
      for x in stride(from: left, to: right, by: CompositionTile.pixelSize) {
        let region = CGRect(x: Double(x) / scale, y: Double(y) / scale,
          width: Double(min(CompositionTile.pixelSize, right - x)) / scale,
          height: Double(min(CompositionTile.pixelSize, bottom - y)) / scale)
        try await drawView(SpatialBoardGrid(camera: camera, outputScale: frame.width / size.width),
          size: size, in: frame, clippingTo: region)
      }
    }
  }

  func drawView<Content: View>(_ content: Content, size: CGSize, in frame: CGRect,
    clippingTo region: CGRect? = nil) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
      .intersection(region ?? CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    // Render artwork directly onto the destination pixel grid. A fractional
    // item origin must not introduce another resampling of grain or thin lines.
    let left = floor(visible.minX * scale), top = floor(visible.minY * scale)
    let width = Int(ceil(visible.maxX * scale) - left)
    let height = Int(ceil(visible.maxY * scale) - top)
    let capture = CGRect(x: left / scale, y: top / scale,
      width: Double(width) / scale, height: Double(height) / scale)
    guard let allocation = resources.reserveRaster(pixelWidth: width + 2, pixelHeight: height + 2, priority: priority)
    else { throw SceneRenderError.resourceLimit }
    defer { allocation.release() }
    let renderer = ImageRenderer(content: content
      .environment(\.displayScale,scale * max(frame.width / size.width,frame.height / size.height))
      .frame(width: size.width, height: size.height)
      .scaleEffect(x: frame.width / size.width, y: frame.height / size.height)
      .position(x: frame.midX - capture.minX, y: frame.midY - capture.minY)
      .frame(width: capture.width, height: capture.height).clipped())
    renderer.scale = scale
    // This owner supplies the admitted pixel grid and color format. The
    // convenience cgImage renderer can change Canvas antialias quantization
    // after another AppKit raster runs, changing an otherwise identical receipt.
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: ((width * 4 + 63) / 64) * 64, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    var rendered = false
    renderer.render(rasterizationScale: scale) { renderedSize, render in
      guard renderedSize == capture.size else { return }
      render(context); rendered = true
    }
    guard rendered, let image = context.makeImage() else { throw SceneRenderError.snapshotPending("physical_artwork") }
    try await buffer.draw(image, in: capture)
    try checkPreparation()
  }

  func drawInk(surface: SurfaceID, journal: SpatialInkJournal, plan: NotebookOrderedInkPlan = .init(), camera: SpatialCamera?,
    size: CGSize, in frame: CGRect) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width * 2 <= 65536, size.height * 2 <= 65536,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    let projectedX = frame.width / size.width, projectedY = frame.height / size.height
    let inkScale = max(2, max(projectedX, projectedY) * scale)
    guard inkScale.isFinite, size.width * inkScale < Double(Int.max / 2),
      size.height * inkScale < Double(Int.max / 2) else { throw SceneRenderError.resourceLimit }
    let pixelsWide = Int(ceil(size.width * inkScale)), pixelsHigh = Int(ceil(size.height * inkScale))
    let sx = Double(pixelsWide) / size.width, sy = Double(pixelsHigh) / size.height
    let local = CGRect(x: (visible.minX - frame.minX) / projectedX,
      y: (visible.minY - frame.minY) / projectedY,
      width: visible.width / projectedX, height: visible.height / projectedY)
    let side = CompositionTile.pixelSize
    let haloX = Int(min(Double(pixelsWide), max(4, ceil(4 * sx / (projectedX * scale)))))
    let haloY = Int(min(Double(pixelsHigh), max(4, ceil(4 * sy / (projectedY * scale)))))
    let firstX = max(0, Int(floor(local.minX * sx)) - haloX)
    let firstY = max(0, Int(floor(local.minY * sy)) - haloY)
    let lastX = min(pixelsWide, Int(ceil(local.maxX * sx)) + haloX)
    let lastY = min(pixelsHigh, Int(ceil(local.maxY * sy)) + haloY)
    // Preserve the physical 2x downsampling phase. Magnified material instead
    // renders vectors on its display grid and assembles only the visible crop;
    // a full magnified cover mask would exhaust the shared native allocation.
    let maskRegion = inkScale > 2
      ? CGRect(x: Double(firstX) / sx, y: Double(firstY) / sy,
        width: Double(lastX - firstX) / sx, height: Double(lastY - firstY) / sy)
      : CGRect(origin: .zero, size: size)
    let nativeGrid = projectedX * scale == inkScale && projectedY * scale == inkScale
      && Double(pixelsWide) == size.width * inkScale && Double(pixelsHigh) == size.height * inkScale
      && (frame.minX * scale).rounded() == frame.minX * scale
      && (frame.minY * scale).rounded() == frame.minY * scale
    let mask = nativeGrid ? nil : try await Self.create(size: maskRegion.size, scale: inkScale,
      resources: resources, priority: priority, permitsPreparation: permitsPreparation)
    // Body-present composition prepares one immutable source for all tiles;
    // the raw-only specialization keeps its existing forward renderer.
    let ordered:(mesh:SpatialInkMesh,geometry:InkOrderedGeometry)?
    let rawJournal:SpatialInkJournal
    var sourceAllocation:RasterReservation?
    defer {sourceAllocation?.release()}
    if plan.isEmpty {
      ordered=nil;rawJournal=journal.presenting(excluding:plan.suppressedInkIDs)
    } else {
      rawJournal=journal
      let limit=resources.byteLimit,viewport=SpatialPoint(x:size.width,y:size.height)
      let estimate=Task.detached(priority:.utility) {
        try SpatialInkMesh.exportPreparationBytes(surface:surface,journal:journal,
          suppressedInkIDs:plan.suppressedInkIDs,camera:camera,viewport:viewport,limit:limit)
      }
      let bytes=try await withTaskCancellationHandler {try await estimate.value} onCancel:{estimate.cancel()}
      try checkPreparation()
      guard let allocation=resources.reserveDerivedBytes(max(1,bytes),priority:priority) else {throw SceneRenderError.resourceLimit}
      sourceAllocation=allocation
      let worker=Task.detached(priority:.utility) {
        try Task.checkCancellation()
        return try SpatialInkMesh.prepare(surface:surface,journal:journal,suppressedInkIDs:plan.suppressedInkIDs)
      }
      let mesh=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
      try checkPreparation()
      guard let device=InkRasterRenderer.shared.device else {throw SceneRenderError.resourceLimit}
      let geometry=try await InkOrderedGeometry(plan,reusing:nil,device:device,resources:resources,owner:nil)
      ordered=(mesh,geometry)
    }
    try checkPreparation()
    for y in stride(from: firstY, to: lastY, by: side) {
      for x in stride(from: firstX, to: lastX, by: side) {
        try checkPreparation()
        let width = min(side, lastX - x), height = min(side, lastY - y)
        let region = CGRect(x: Double(x) / sx, y: Double(y) / sy,
          width: Double(width) / sx, height: Double(height) / sy)
        // MSAA, resolve texture and CPU readback coexist for one 512-pixel region.
        guard let allocation = resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 8, priority: priority)
        else { throw SceneRenderError.resourceLimit }
        do {
          let image:CGImage?
          if let ordered {
            image=try await InkRasterRenderer.shared.orderedImage(mesh:ordered.mesh,plan:plan,
              camera:camera,viewport:.init(x:size.width,y:size.height),region:region,scale:inkScale,
              resources:resources,preparedGeometry:ordered.geometry,priority:priority)
          } else {
            let shiftedCamera=camera.map {
              SpatialCamera(center:$0.screenToWorld(.init(x:region.midX,y:region.midY),
                viewport:.init(x:size.width,y:size.height)),scale:$0.scale)
            }
            let worker=Task.detached(priority:.utility) {
              try Task.checkCancellation()
              let layers=shiftedCamera.map { SpatialInkComposer.boardLayers(board:surface,journal:rawJournal,
                camera:$0,viewport:.init(x:region.width,y:region.height)) }
                ?? SpatialInkComposer.localLayers(for:surface,journal:rawJournal,origin:.init(x:region.minX,y:region.minY))
              guard !layers.isEmpty else {return nil as CGImage?}
              try await InkRasterRenderer.shared.prepareInk()
              guard let image=InkRasterRenderer.shared.render(layers:layers,size:region.size,scale:inkScale) else {
                throw SceneRenderError.snapshotPending("ink_pixels")
              }
              try Task.checkCancellation();return image
            }
            image=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
          }
          try checkPreparation()
          if let image {
            if let mask {try await mask.buffer.draw(image,in:region.offsetBy(dx: -maskRegion.minX, dy: -maskRegion.minY))}
            else {
              try await buffer.draw(image,in:.init(x:frame.minX+region.minX*projectedX,
                y:frame.minY+region.minY*projectedY,width:region.width*projectedX,height:region.height*projectedY))
            }
          }
          allocation.release()
        } catch { allocation.release(); throw error }
      }
    }
    // Assemble before projection so independently sampled edges never blend twice.
    if let mask { try await mask.finishInto(self, in: .init(
      x: frame.minX + maskRegion.minX * projectedX, y: frame.minY + maskRegion.minY * projectedY,
      width: maskRegion.width * projectedX, height: maskRegion.height * projectedY)) }
  }

  private func finishInto(_ destination: SceneRasterCompositor, in frame: CGRect) async throws {
    try checkPreparation(); try destination.checkPreparation()
    let image = try await buffer.finishImage()
    try await destination.buffer.draw(image, in: frame)
    try checkPreparation(); try destination.checkPreparation()
    isFinished = true; reservation.release()
  }

  func pushClip(_ path: sending CGPath) async throws { try checkPreparation(); try await buffer.pushClip(path) }
  func popClip() async throws { try checkPreparation(); try await buffer.popClip() }

  func finishImage() async throws -> SceneRasterImage {
    try checkPreparation()
    let image = try await buffer.finishImage()
    try checkPreparation()
    isFinished = true; transfersReservation = true
    return .init(image: image, reservation: reservation)
  }

  func finishPNG() async throws -> Data {
    try checkPreparation()
    let png = try await buffer.finishPNG()
    try checkPreparation()
    isFinished = true
    reservation.release()
    return png
  }

  /// Ownership transfers directly from the accounted output buffer to the
  /// shared image cache. No decode or unaccounted image survives this boundary.
  func finishRaster(for source: SceneRasterSource) async throws -> RasterLease {
    try checkPreparation()
    guard priority == .passive else { throw SceneRenderError.resourceLimit }
    let pixels = try await buffer.finishImage()
    try checkPreparation()
    #if os(iOS)
      let image = UIImage(cgImage: pixels, scale: 1, orientation: .up)
    #else
      let image = NSImage(cgImage: pixels, size: .init(width: pixels.width, height: pixels.height))
    #endif
    guard let retained = resources.storeAndRetain(image, for: source, reservation: reservation)
    else { throw SceneRenderError.resourceLimit }
    isFinished = true
    return retained
  }

  private func checkPreparation() throws {
    try Task.checkCancellation()
    guard !isFinished, permitsPreparation() else { throw CancellationError() }
  }

  isolated deinit { if !transfersReservation { reservation.release() } }
}

/// An accounted CPU image can be borrowed by the native compositor directly;
/// passing it to Metal requires neither PNG serialization nor a cache alias.
@MainActor
final class SceneRasterImage {
  let image: CGImage
  private let reservation: RasterReservation
  init(image: CGImage, reservation: RasterReservation) { self.image = image; self.reservation = reservation }
  isolated deinit { reservation.release() }
}

/// A single current WebKit frame, scoped to its accepted turn. This holds the
/// capture grant directly; unlike a RasterLease it has no passive cache alias.
@MainActor
final class SceneRasterCut {
  let source: SceneRasterSource
  let pixelScale: Double
  private let pixels: SceneRasterImage
  var image: CGImage { pixels.image }
  init(source: SceneRasterSource, pixelScale: Double, pixels: SceneRasterImage) {
    self.source = source; self.pixelScale = pixelScale; self.pixels = pixels
  }
}

/// A bounded, geometrically grown output for the existing ImageIO encoder.
/// The callback owns no full-frame copy and checks pool admission before growth.
private final class BoundedPNGOutput: @unchecked Sendable {
  static let overhead = 4096
  private let maximumBytes: Int
  private let resizeCharge: @MainActor @Sendable (Int) -> Bool
  private let lock = NSLock()
  private var buffer: UnsafeMutableRawPointer?
  private var capacity = 0
  private var count = 0
  private var failure: SceneRenderError?
  private var finished = false

  init(maximumBytes: Int, resizeCharge: @escaping @MainActor @Sendable (Int) -> Bool) {
    self.maximumBytes = maximumBytes; self.resizeCharge = resizeCharge
  }
  deinit { free(buffer) }

  func consumer() -> CGDataConsumer? {
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
      guard let info else { return 0 }
      return Unmanaged<BoundedPNGOutput>.fromOpaque(info).takeUnretainedValue().write(bytes, count: count)
    }, releaseConsumer: { info in
      if let info { Unmanaged<BoundedPNGOutput>.fromOpaque(info).release() }
    })
    let info = Unmanaged.passRetained(self).toOpaque()
    guard let value = CGDataConsumer(info: info, cbks: &callbacks) else {
      Unmanaged<BoundedPNGOutput>.fromOpaque(info).release(); return nil
    }
    return value
  }

  private func charge(_ bytes: Int) -> Bool {
    // encodePNG is async off-main; neither caller nor this callback blocks
    // MainActor waiting for ImageIO. Only the synchronous ledger is entered.
    assert(!Thread.isMainThread)
    return DispatchQueue.main.sync { MainActor.assumeIsolated { resizeCharge(bytes) } }
  }

  private func write(_ bytes: UnsafeRawPointer, count incoming: Int) -> Int {
    lock.lock(); defer { lock.unlock() }
    guard !finished, failure == nil, !Task.isCancelled,
      incoming >= 0, incoming <= maximumBytes - count else {
      failure = .resourceLimit; return 0
    }
    let needed = count + incoming
    if needed > capacity {
      let requested = min(maximumBytes, max(4096, needed, capacity * 2))
      let next = malloc_good_size(requested)
      guard charge(capacity + next + Self.overhead), let replacement = realloc(buffer, next) else {
        failure = .resourceLimit; return 0
      }
      buffer = replacement; capacity = malloc_size(replacement)
      guard charge(capacity + Self.overhead) else { failure = .resourceLimit; return 0 }
    }
    if incoming > 0 { memcpy(buffer!.advanced(by: count), bytes, incoming) }
    count = needed
    return incoming
  }

  func check() throws {
    lock.lock(); defer { lock.unlock() }
    if let failure { throw failure }
  }

  func finish() throws -> (Data, Int) {
    lock.lock(); defer { lock.unlock() }
    guard !finished, failure == nil, let buffer, count > 0 else { throw SceneRenderError.resourceLimit }
    finished = true; self.buffer = nil
    return (Data(bytesNoCopy: buffer, count: count, deallocator: .free), capacity + Self.overhead)
  }
}

/// Pixel allocation, blending and PNG encoding run outside the UI actor. This
/// actor serializes one composition; it is neither a source cache nor a writer.
actor CompositionPixels {
  /// ImageIO writes only admitted output bytes. Growth charges old and new
  /// allocations together before realloc; the completed Data adopts the buffer.
  /// The synchronous pool callback is short and never waits for this encoder.
  static func encodePNG(_ image: CGImage, maximumBytes: Int,
    resizeCharge: @escaping @MainActor @Sendable (Int) -> Bool) async throws -> RasterEncodedBytes {
    assert(!Thread.isMainThread, "PNG encoding must not run on the UI thread")
    try Task.checkCancellation()
    let output = BoundedPNGOutput(maximumBytes: maximumBytes, resizeCharge: resizeCharge)
    guard let consumer = output.consumer(),
      let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil)
    else { throw SceneRenderError.snapshotPending("png_encoding") }
    CGImageDestinationAddImage(destination, image, nil)
    let completed = CGImageDestinationFinalize(destination)
    try Task.checkCancellation()
    try output.check()
    guard completed else { throw SceneRenderError.snapshotPending("png_encoding") }
    let (data, cost) = try output.finish()
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try Task.checkCancellation()
    return RasterEncodedBytes(png: data, sha256: hash, accountedByteCount: cost)
  }

  /// Pure, cancellable pixel work uses the same non-UI execution boundary as
  /// composition. The caller owns the charged source and destination lifetime.
  static func makeMipmaps(_ original: CGImage, sizes: [(width: Int, height: Int)]) async throws -> [CGImage] {
    assert(!Thread.isMainThread, "Mipmap pixel work must not run on the UI thread")
    let space = original.colorSpace?.model == .rgb ? original.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
    guard let space else { throw SceneRenderError.resourceLimit }
    var previous = original, levels: [CGImage] = []
    for size in sizes {
      try Task.checkCancellation()
      guard let context = CGContext(data: nil, width: size.width, height: size.height,
        bitsPerComponent: 8, bytesPerRow: ((size.width * 4 + 63) / 64) * 64, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
      context.interpolationQuality = .high; context.setBlendMode(.copy)
      context.draw(previous, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
      guard let level = context.makeImage() else { throw SceneRenderError.resourceLimit }
      levels.append(level); previous = level
    }
    return levels
  }

  private var context: CGContext?
  private var clipDepth = 0
  private let size: CGSize
  private let scale: Double

  static func create(size: CGSize, width: Int, height: Int, scale: Double) async throws -> CompositionPixels {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: ((width * 4 + 63) / 64) * 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: Double(height))
    context.scaleBy(x: Double(width) / size.width, y: -Double(height) / size.height)
    context.interpolationQuality = .high
    return Self(context: context, size: size, scale: scale)
  }

  private init(context: sending CGContext, size: CGSize, scale: Double) {
    self.context = context; self.size = size; self.scale = scale
  }

  func drawPNG(_ data: Data, in frame: CGRect) throws {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw SceneRenderError.snapshotPending("base_pixels")
    }
    try draw(image, in: frame)
  }

  func draw(_ image: CGImage, in frame: CGRect) throws {
    try Task.checkCancellation()
    guard let context else { throw CancellationError() }
    guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.snapshotPending("invalid_frame") }
    context.saveGState()
    // Sources use top-left page coordinates; CGImage drawing itself is y-up.
    context.translateBy(x: frame.minX, y: frame.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: frame.size))
    context.restoreGState()
  }

  func drawPaper(size: CGSize, in frame: CGRect) throws {
    try Task.checkCancellation()
    guard let context else { throw CancellationError() }
    let projectedX = frame.width / size.width, projectedY = frame.height / size.height
    let displayScale = scale * max(projectedX, projectedY)
    guard displayScale.isFinite, displayScale > 0 else { throw SceneRenderError.resourceLimit }
    context.saveGState()
    defer { context.restoreGState() }
    // The destination already uses top-left coordinates. Keep the paper origin
    // when exporting a crop so grid lines have the same phase as the full page.
    context.translateBy(x: frame.minX, y: frame.minY)
    context.scaleBy(x: projectedX, y: projectedY)
    let bounds = CGRect(origin: .zero, size: size)
    context.clip(to: bounds)
    let background = PaperAppearance.background, grid = PaperAppearance.grid
    context.setFillColor(CGColor(srgbRed: background.red, green: background.green,
      blue: background.blue, alpha: 1))
    context.fill(bounds)
    context.setStrokeColor(CGColor(srgbRed: grid.red, green: grid.green,
      blue: grid.blue, alpha: PaperAppearance.gridOpacity))
    context.setLineWidth(1 / displayScale)
    context.addPath(PaperAppearance.gridPath(size: size))
    context.strokePath()
    try Task.checkCancellation()
  }

  func pushClip(_ path: sending CGPath) throws {
    try Task.checkCancellation()
    guard let context else { throw CancellationError() }
    context.saveGState(); context.addPath(path); context.clip(); clipDepth += 1
  }
  func popClip() throws {
    guard let context, clipDepth > 0 else { throw CancellationError() }
    context.restoreGState(); clipDepth -= 1
  }

  func finishImage() throws -> CGImage {
    try Task.checkCancellation()
    guard clipDepth == 0, let context, let image = context.makeImage() else { throw CancellationError() }
    self.context = nil
    return image
  }

  func finishPNG() throws -> Data {
    try Task.checkCancellation()
    guard clipDepth == 0, let context, let image = context.makeImage() else { throw CancellationError() }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw SceneRenderError.snapshotPending("png_encoding") }
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw SceneRenderError.snapshotPending("png_encoding") }
    self.context = nil
    return data as Data
  }
}

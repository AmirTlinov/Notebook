import CoreGraphics
import ImageIO
import NotebookCore
import SwiftUI

/// Physical paper, ordered agent layers, then final pen/erase pixels. Both an
/// exact export and a frozen question choose their own source-raster resolver;
/// neither can read a new page or another camera during composition.
@MainActor
enum PageCompositionRenderer {
  static func elements(in page: PageDocument, region: PageRect, elementID: String?) -> [AgentElement] {
    let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    let graphics = page.graphicPresentation.geometryIDs
    let graph = page.graphicGraph()
    return page.elements.filter {
      let frame = graph.resolve($0.id).layout?.frame ?? $0.frame
      return (elementID == nil || elementID == $0.id)
        && ($0.graphic == nil || graphics.contains($0.id))
        && ($0.graphic == nil || graph.resolve($0.id).layout != nil)
        && bounds.intersects(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
    }
  }

  static func render(_ page: PageDocument, region: PageRect? = nil, elementID: String? = nil,
    scale: Double = 2, resources: SceneRenderResources = .shared,
    permitsPreparation: @escaping @MainActor () -> Bool = { true },
    raster: @escaping @MainActor (AgentElement) async throws -> RasterLease
  ) async throws -> SceneCompositionRenderer.Result {
    let region = region ?? .init(x: 0, y: 0, width: page.size.width, height: page.size.height)
    guard region.x >= 0, region.y >= 0,
      region.x + region.width <= page.size.width, region.y + region.height <= page.size.height,
      elementID == nil || page.elements.contains(where: { $0.id == elementID }) else {
      throw SceneRenderError.snapshotPending("page_region")
    }
    let size = CGSize(width: page.size.width, height: page.size.height)
    let frame = CGRect(x: -region.x, y: -region.y, width: size.width, height: size.height)
    let canvas = try await SceneRasterCompositor.create(size: .init(width: region.width, height: region.height),
      scale: scale, resources: resources, permitsPreparation: permitsPreparation)
    // A selected element authorizes only that layer. Its transparent pixels do
    // not expose another element or the handwriting underneath it.
    if elementID == nil {
      try await canvas.drawView(GridPaperView().environment(\.displayScale, scale), size: size, in: frame)
    }
    let graph = page.graphicGraph()
    let erasures = try PageInkDrawing.decode(page.drawingData).elementErasures
    for element in elements(in: page, region: region, elementID: elementID) {
      try Task.checkCancellation()
      // The resolver returns a borrowed entry. A frozen selection owns its
      // lease, whereas the export resolver releases its previous entry.
      let layout = element.graphic == nil ? nil : graph.resolve(element.id).layout
      let local = layout?.frame ?? element.frame
      let frame = CGRect(x: local.x - region.x, y: local.y - region.y,
        width: local.width, height: local.height)
      let cuts = erasures[element.id] ?? []
      // Export must not send a dense live triangle mask to ImageRenderer on
      // the main actor. Prepare the same canonical appearance as scene picking.
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: frame.size, erasures: cuts).prepared()
      if let graphic = element.graphic {
        try await canvas.drawView(NotebookGraphicView(graphic: graphic, layout:layout, erasures:cuts,appearance:appearance), size: frame.size, in: frame)
        continue
      }
      if element.kind == .nativeText {
        try await canvas.drawView(NotebookNativeTextSnapshot(source:element.source,style:element.textStyle ?? .standard)
          .erased(by:cuts,appearance:appearance),size:frame.size,in:frame)
        continue
      }
      let image = try await raster(element)
      if let crop = image.source.captureRegion {
        let captured = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        let requested = CGRect(x: -frame.minX, y: -frame.minY, width: region.width, height: region.height)
          .intersection(CGRect(origin: .zero, size: frame.size))
        guard !requested.isNull, captured.contains(requested) else {
          throw SceneRenderError.snapshotPending("historical_region_unavailable")
        }
        try await canvas.draw(image, in: captured.offsetBy(dx: frame.minX, dy: frame.minY), erasures: erasures[element.id] ?? [], elementFrame: frame)
      } else {
        try await canvas.draw(image, in: frame, erasures: erasures[element.id] ?? [])
      }
      canvas.recordDiagnostics(resources.diagnostics(for: [element]))
    }
    if elementID == nil { try await drawInk(page, size: size, frame: frame, resources: resources, canvas: canvas) }
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  private static func drawInk(_ page: PageDocument, size: CGSize, frame: CGRect,
    resources: SceneRenderResources, canvas: SceneRasterCompositor) async throws {
    guard !page.drawingData.isEmpty else { return }
    let suppressed = page.graphicPresentation.suppressedInkIDs
    let decode = Task.detached(priority: .utility) { try PageInkDrawing.decode(page.drawingData).presenting(excluding: suppressed) }
    let drawing = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
    guard !drawing.isEmpty else { return }
    // Keep the same physical 2x mask and sampling phase as live page ink. The
    // output clips to the granted region; raw endpoints never leave this owner.
    guard let pixels = resources.reserveRaster(pixelWidth: Int(ceil(size.width * 2)),
      pixelHeight: Int(ceil(size.height * 2)), backingCount: 8) else { throw SceneRenderError.resourceLimit }
    defer { pixels.release() }
    var geometryBytes = 0
    for action in drawing.actions where action.isActive {
      // Round sweeps retain a disk per sample in both CPU vertices and GPU
      // buffers; the old pen-only estimate would undercharge these allocations.
      let bytesPerSample = action.tool == .eraser
        ? 512 + 2 * InkStrokeGeometry.roundSweepSegmentVertexCount * MemoryLayout<SpatialInkGeometry.Vertex>.stride : 512
      let samples = action.samples.count.multipliedReportingOverflow(by: bytesPerSample)
      let total = geometryBytes.addingReportingOverflow(samples.partialValue)
      guard !samples.overflow, !total.overflow, total.partialValue <= resources.byteLimit - 2304 else {
        throw SceneRenderError.resourceLimit
      }
      geometryBytes = total.partialValue + 2304
    }
    var baselineBytes = 0
    if let png = drawing.baselinePNG {
      guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0, width <= 8192, height <= 8192 else {
        throw SceneRenderError.snapshotPending("baseline_pixels")
      }
      baselineBytes = width * height * 8
    }
    guard geometryBytes <= resources.byteLimit - baselineBytes,
      let geometry = resources.reserveDerivedBytes(max(1, geometryBytes + baselineBytes), priority: .passive) else {
      throw SceneRenderError.resourceLimit
    }
    defer { geometry.release() }
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      guard let image = InkRasterRenderer.shared.page(drawing, size: size) else {
        throw SceneRenderError.snapshotPending("ink_pixels")
      }
      try Task.checkCancellation()
      return image
    }
    let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    try await canvas.drawImage(image, in: frame)
  }
}

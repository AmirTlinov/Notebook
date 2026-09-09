import CoreGraphics
import ImageIO
import NotebookCore
import SwiftUI

/// Physical paper, final pen/erase pixels, then ordered agent layers. Both an
/// exact export and a frozen question choose their own source-raster resolver;
/// neither can read a new page or another camera during composition.
@MainActor
enum PageCompositionRenderer {
  static func elements(in page: PageDocument, region: PageRect, elementID: String?) -> [AgentElement] {
    let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    return page.elements.filter {
      (elementID == nil || elementID == $0.id)
        && bounds.intersects(CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height))
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
      try await drawInk(page, size: size, frame: frame, resources: resources, canvas: canvas)
    }
    for element in elements(in: page, region: region, elementID: elementID) {
      try Task.checkCancellation()
      let image = try await raster(element)
      // The resolver returns a borrowed entry. A frozen selection owns its
      // lease, whereas the export resolver releases its previous entry.
      try await canvas.draw(image, in: CGRect(x: element.frame.x - region.x, y: element.frame.y - region.y,
        width: element.frame.width, height: element.frame.height))
      canvas.recordDiagnostics(resources.diagnostics(for: [element]))
    }
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  private static func drawInk(_ page: PageDocument, size: CGSize, frame: CGRect,
    resources: SceneRenderResources, canvas: SceneRasterCompositor) async throws {
    guard !page.drawingData.isEmpty else { return }
    let decode = Task.detached(priority: .utility) { try PageInkDrawing.decode(page.drawingData) }
    let drawing = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
    guard !drawing.isEmpty else { return }
    // Keep the same physical 2x mask and sampling phase as live page ink. The
    // output clips to the granted region; raw endpoints never leave this owner.
    guard let pixels = resources.reserveRaster(pixelWidth: Int(ceil(size.width * 2)),
      pixelHeight: Int(ceil(size.height * 2)), backingCount: 8) else { throw SceneRenderError.resourceLimit }
    defer { pixels.release() }
    var geometryBytes = 0
    for action in drawing.actions where action.isActive {
      let samples = action.samples.count.multipliedReportingOverflow(by: 512)
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

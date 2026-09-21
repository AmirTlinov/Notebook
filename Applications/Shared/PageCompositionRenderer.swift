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
    return page.elements.filter { element in
      let presentation=element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0) } : nil
      guard let frame=graph.resolve(element.id).layout?.frame ?? presentation?.frame else { return false }
      return element.kind != .group && (elementID == nil || elementID == element.id)
        && (element.graphic == nil || graphics.contains(element.id))
        && (element.graphic == nil || graph.resolve(element.id).layout != nil)
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
      let presentation=element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0) } : nil
      guard let local=layout?.frame ?? presentation?.frame else { continue }
      let frame = CGRect(x: local.x - region.x, y: local.y - region.y,
        width: local.width, height: local.height)
      let cuts = erasures[element.id] ?? []
      // Export must not send a dense live triangle mask to ImageRenderer on
      // the main actor. Prepare the same canonical appearance as scene picking.
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: presentation?.bodySize ?? frame.size, erasures: cuts).prepared()
      if let graphic = element.graphic {
        try await canvas.drawView(NotebookGraphicView(graphic: graphic, layout:layout, erasures:cuts,appearance:appearance,live:false), size: frame.size, in: frame)
        continue
      }
      if element.kind == .nativeText {
        try await canvas.drawView(NotebookPlacedElement(presentation:presentation) {
          NotebookNativeTextSnapshot(source:element.source,style:element.textStyle ?? .standard).erased(by:cuts,appearance:appearance)
        },size:frame.size,in:frame)
        continue
      }
      let image = try await raster(agentElementSnapshotSource(element))
      guard image.pixelScale + 0.000_001 >= scale * (presentation?.maximumScale ?? 1) else {
        throw SceneRenderError.snapshotPending("source_density")
      }
      if let crop = image.source.captureRegion {
        let captured = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        guard let presentation else { throw SceneRenderError.snapshotPending("element_placement") }
        let requested = CGRect(x:region.x,y:region.y,width:region.width,height:region.height)
          .applying(presentation.placement.transform.inverted())
          .intersection(CGRect(origin:.zero,size:presentation.bodySize))
        guard !requested.isNull, captured.contains(requested) else {
          throw SceneRenderError.snapshotPending("historical_region_unavailable")
        }
        let destination=captured.applying(presentation.transform)
          .offsetBy(dx:frame.minX,dy:frame.minY)
        try await canvas.draw(image, in: destination, erasures: erasures[element.id] ?? [], elementFrame: frame,presentation:presentation)
      } else {
        try await canvas.draw(image, in: frame, erasures: erasures[element.id] ?? [],presentation:presentation)
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
    let byteLimit=resources.byteLimit
    let decode = Task.detached(priority: .utility) {
      let drawing=try PageInkDrawing.decode(page.drawingData).presenting(excluding:suppressed)
      return try (drawing,inkGeometryBytes(drawing,size:size,limit:byteLimit))
    }
    let (drawing,geometryBytes) = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
    guard !drawing.isEmpty else { return }
    // Keep the same physical 2x mask and sampling phase as live page ink. The
    // output clips to the granted region; raw endpoints never leave this owner.
    guard let pixels = resources.reserveRaster(pixelWidth: Int(ceil(size.width * 2)),
      pixelHeight: Int(ceil(size.height * 2)), backingCount: 8) else { throw SceneRenderError.resourceLimit }
    defer { pixels.release() }
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

  /// Admission follows the same virtual ranges as InkRasterRenderer. A compact
  /// million-event body must not be charged for a million unbuilt GPU nodes.
  /// The query runs on the worker; ambiguous coalescing still pays for the full
  /// normalizer, and overlapping visible repeats still pay for every draw.
  nonisolated private static func inkGeometryBytes(_ drawing: PageInkDrawing,size: CGSize,limit: Int) throws -> Int {
    var total=0
    func add(_ count: Int,_ stride: Int = 1) throws {
      let bytes=count.multipliedReportingOverflow(by:stride)
      let sum=total.addingReportingOverflow(bytes.partialValue)
      guard !bytes.overflow,!sum.overflow,sum.partialValue <= limit else { throw SceneRenderError.resourceLimit }
      total=sum.partialValue
    }
    // page() uses physical 2x pixels and the same half-point AA margin.
    let viewport=CGRect(origin:.zero,size:size).insetBy(dx:-0.5,dy:-0.5)
    for action in drawing.actions where action.isActive {
      try Task.checkCancellation()
      try add(action.samples.payloadBytes);try add(2304)
      let source=InkSampleRelations(action)
      if source.count > InkRenderGeometry.maximumSegments,
        let relative=SpatialInkGeometry.RelativeSource(source,projection:.init()) {
        // Account for the bounded query's result capacity before asking for it.
        try add(relative.chunkCount,2*MemoryLayout<Range<Int>>.stride)
        for id in relative.query(viewport:viewport).chunks {
          // CPU halo, prepared nodes/LOD, selected copy and Metal buffer.
          try add(relative.preparationPointLimit(id),512)
        }
      } else { try add(source.count,512) }
    }
    return total
  }
}

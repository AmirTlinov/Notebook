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
    elements(in: page, region: region, elementID: elementID, graph: page.graphicGraph())
  }

  private static func elements(in page: PageDocument, region: PageRect, elementID: String?,
    graph: NotebookGraphicGraph) -> [AgentElement] {
    let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    let graphics = page.graphicPresentation.geometryIDs
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
    try await render(page, region: region, elementID: elementID, scale: scale, resources: resources,
      permitsPreparation: permitsPreparation, inkOnly: false, raster: raster)
  }

  /// The transparent regional proof uses the exact same accepted drawing,
  /// source-anchored contact plan and cuts as the full physical page.
  static func renderInk(_ page: PageDocument, scale: Double = 2,
    resources: SceneRenderResources = .shared,
    permitsPreparation: @escaping @MainActor () -> Bool = { true }
  ) async throws -> SceneCompositionRenderer.Result {
    try await render(page, region: nil, elementID: nil, scale: scale, resources: resources,
      permitsPreparation: permitsPreparation, inkOnly: true) { _ in
        throw SceneRenderError.snapshotPending("ink_source_scope")
      }
  }

  private static func render(_ page: PageDocument, region: PageRect?, elementID: String?, scale: Double,
    resources: SceneRenderResources, permitsPreparation: @escaping @MainActor () -> Bool,
    inkOnly: Bool, raster: @escaping @MainActor (AgentElement) async throws -> RasterLease
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
    if elementID == nil, !inkOnly {
      try await canvas.drawView(GridPaperView().environment(\.displayScale, scale), size: size, in: frame)
    }
    let graph = page.graphicGraph()
    // One immutable accepted source serves ranks, target cuts and the raw mesh.
    // No archive encoding/decoding roundtrip or newer model read follows an await.
    let source=page.inkSource
    let decode=Task.detached(priority:.utility) {
      let drawing=try source.drawing()
      try Task.checkCancellation()
      return (drawing,drawing.elementErasures)
    }
    let (drawing,erasures)=try await withTaskCancellationHandler { try await decode.value } onCancel:{decode.cancel()}
    try Task.checkCancellation()
    let selected=elements(in:page,region:region,elementID:elementID,graph:graph)
    let layouts=Dictionary(uniqueKeysWithValues:selected.compactMap { element in
      graph.resolve(element.id).layout.map { (element.id,$0) }
    })
    let input=NotebookPageOrderedInkInput(elements:selected,graph:graph,layouts:layouts,
      erasures:erasures,suppressedInkIDs:page.graphicPresentation.suppressedInkIDs)
    let plan=try input.plan(drawing:drawing)
    let orderedIDs=plan.elementIDs
    for element in selected where !inkOnly {
      try Task.checkCancellation()
      // The resolver returns a borrowed entry. A frozen selection owns its
      // lease, whereas the export resolver releases its previous entry.
      let layout = element.graphic == nil ? nil : layouts[element.id]
      let presentation=element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element,placement:$0) } : nil
      guard let local=layout?.frame ?? presentation?.frame else { continue }
      let frame = CGRect(x: local.x - region.x, y: local.y - region.y,
        width: local.width, height: local.height)
      let cuts = erasures[element.id] ?? []
      let paintsMeasuredBody = !orderedIDs.contains(element.id)
      // A source-anchored body is painted once in its raw rank. Its label stays
      // in the authored layer, and selected-element export keeps that label.
      if !paintsMeasuredBody, element.graphic?.label.isEmpty != false { continue }
      // Export must not send a dense live triangle mask to ImageRenderer on
      // the main actor. Prepare the same canonical appearance as scene picking.
      let appearance = try await NotebookElementErasureCache.Input(graphic: element.graphic,
        layout: layout, size: presentation?.bodySize ?? frame.size, erasures: cuts).prepared()
      if let graphic = element.graphic {
        try await canvas.drawView(NotebookGraphicView(graphic: graphic, layout:layout, erasures:cuts,appearance:appearance,live:false,paintsMeasuredBody:paintsMeasuredBody), size: frame.size, in: frame)
        continue
      }
      if element.kind == .nativeText {
        try await canvas.drawView(NotebookPlacedElement(presentation:presentation) {
          NotebookNativeTextSnapshot(source:element.source,style:element.textStyle ?? .standard)
            .snapshotErased(by:cuts,appearance:appearance)
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
    if elementID == nil || !plan.isEmpty {
      try await drawInk(elementID == nil ? drawing : .init(), plan:plan,
        size:size,frame:frame,resources:resources,canvas:canvas)
    }
    let png = try await canvas.finishPNG()
    return .init(png: png, diagnostics: canvas.diagnostics)
  }

  private static func drawInk(_ drawing:PageInkDrawing,plan:NotebookOrderedInkPlan,size:CGSize,frame:CGRect,
    resources:SceneRenderResources,canvas:SceneRasterCompositor) async throws {
    guard !drawing.isEmpty || !plan.isEmpty else {return}
    let byteLimit=resources.byteLimit
    let prepare=Task.detached(priority:.utility) {
      try Task.checkCancellation()
      return try inkGeometryBytes(drawing,excluding:plan.suppressedInkIDs,size:size,limit:byteLimit)
    }
    let geometryBytes=try await withTaskCancellationHandler {try await prepare.value} onCancel:{prepare.cancel()}
    try Task.checkCancellation()
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
    let image:CGImage
    if plan.isEmpty {
      // No extracted body: preserve the existing forward page specialization.
      let worker=Task.detached(priority:.utility) {
        try Task.checkCancellation()
        guard let image=InkRasterRenderer.shared.page(drawing.presenting(excluding:plan.suppressedInkIDs),size:size) else {
          throw SceneRenderError.snapshotPending("ink_pixels")
        }
        try Task.checkCancellation();return image
      }
      image=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
    } else {
      let worker=Task.detached(priority:.utility) {
        try Task.checkCancellation()
        return SpatialInkMesh.page(drawing,suppressedInkIDs:plan.suppressedInkIDs)
      }
      let mesh=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
      guard let device=InkRasterRenderer.shared.device else {throw SceneRenderError.resourceLimit}
      let prepared=try await InkOrderedGeometry(plan,reusing:nil,device:device,resources:resources,owner:nil)
      image=try await InkRasterRenderer.shared.orderedImage(mesh:mesh,plan:plan,camera:nil,
        viewport:.init(x:size.width,y:size.height),region:.init(origin:.zero,size:size),scale:2,
        resources:resources,preparedGeometry:prepared,baselinePNG:drawing.baselinePNG)
    }
    try await canvas.drawImage(image, in: frame)
  }

  /// Admission follows the same virtual ranges as InkRasterRenderer. A compact
  /// million-event body must not be charged for a million unbuilt GPU nodes.
  /// The query runs on the worker; ambiguous coalescing still pays for the full
  /// normalizer, and overlapping visible repeats still pay for every draw.
  nonisolated private static func inkGeometryBytes(_ drawing: PageInkDrawing,excluding suppressed:Set<UUID>,size: CGSize,limit: Int) throws -> Int {
    var total=0
    func add(_ count: Int,_ stride: Int = 1) throws {
      let bytes=count.multipliedReportingOverflow(by:stride)
      let sum=total.addingReportingOverflow(bytes.partialValue)
      guard !bytes.overflow,!sum.overflow,sum.partialValue <= limit else { throw SceneRenderError.resourceLimit }
      total=sum.partialValue
    }
    // page() uses physical 2x pixels and the same half-point AA margin.
    let viewport=CGRect(origin:.zero,size:size).insetBy(dx:-0.5,dy:-0.5)
    for action in drawing.actions where action.isActive && !suppressed.contains(action.id) {
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

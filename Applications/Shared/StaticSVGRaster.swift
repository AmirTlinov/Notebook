import CoreGraphics
import NotebookCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Data-only vectors use the same bounded SVG kernel as printed images. This
/// adapter only projects its PDF into the existing source raster lease: no DOM,
/// JavaScript, hidden window, separate image cache or alternative material.
@MainActor
enum StaticSVGRaster {
  static func prepare(_ element: AgentElement, resources: SceneRenderResources,
    policy initialPolicy: AgentSnapshotPolicy, captureRequest: SceneRasterCaptureRequest? = nil,
    permitsPreparation: @MainActor () -> Bool) async throws -> RasterLease {
    precondition(element.usesNativeSVGRaster)
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    // The inner SVG's percentages resolve against its authored physical frame,
    // never the camera's crop. Native admission excludes browser text/layout.
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='\(element.frame.width)' height='\(element.frame.height)' color='#171714'>\(element.html)</svg>"
    let pdf = try await DocumentCanonicalPrint.store.vectorPDF(Data(svg.utf8))
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    guard let sourceReservation = resources.reserveDerivedBytes(pdf.count, priority: .passive) else { throw SceneRenderError.resourceLimit }
    defer { sourceReservation.release() }
    while true {
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      let policy = captureRequest?.policy ?? initialPolicy
      let source = policy.rasterSource(for: element)
      if let hit = resources.retainRaster(for: source, minimumScale: policy.minimumScale(for: element)) { return hit }
      guard let pixels = policy.pixelSize(for: element),
        let reservation = resources.reserveWebSnapshot(pixelSize: pixels) else { throw SceneRenderError.resourceLimit }
      defer { reservation.release() }
      let crop = policy.captureRect(for: element), frame = element.frame
      let task = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
          document.numberOfPages == 1, let page = document.page(at: 1),
          let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: ((Int(pixels.width) * 4 + 63) / 64) * 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SceneRenderError.resourceLimit }
        // Quartz is bottom-up; capture addresses are top-down local material.
        context.translateBy(x: -crop.minX * pixels.width / crop.width,
          y: (crop.maxY - frame.height) * pixels.height / crop.height)
        context.scaleBy(x: frame.width * pixels.width / crop.width,
          y: frame.height * pixels.height / crop.height)
        context.concatenate(page.getDrawingTransform(.mediaBox,
          rect: .init(x: 0, y: 0, width: 1, height: 1), rotate: 0, preserveAspectRatio: false))
        context.drawPDFPage(page)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw SceneRenderError.resourceLimit }
        #if os(iOS)
        let levels = try await CompositionPixels.makeMipmaps(image,
          sizes: SceneRenderResources.mipmapSizes(width: image.width, height: image.height))
        #else
        let levels: [CGImage] = []
        #endif
        return (image, levels)
      }
      let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      let cg = result.0
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      if let captureRequest, captureRequest.policy != policy { continue }
      #if os(iOS)
      let image = UIImage(cgImage: cg, scale: pixels.width / crop.width, orientation: .up)
      #else
      let image = NSImage(cgImage: cg, size: crop.size)
      #endif
      // Pixel work stays on its worker through minification. Returning to the
      // UI between drawing and mipmaps put every dense-page element behind
      // another layout cycle. The same reservation admits all exact levels.
      guard let raster = resources.storeAndRetain(image, for: source, reservation: reservation,
        mipmaps: result.1) else {
        try Task.checkCancellation()
        guard permitsPreparation() else { throw CancellationError() }
        if let captureRequest, captureRequest.policy != policy { continue }
        throw SceneRenderError.resourceLimit
      }
      return raster
    }
  }
}

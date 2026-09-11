import UIKit
import NotebookCore

/// Replays preserved TextKit geometry and the existing ink compositor, never
/// the current file or a screenshot of a chat obscuring the material.
@MainActor enum NotebookCodeImageRenderer {
  static func render(_ annotation: NotebookCodeAnnotation, reference: CollaborationReference,
    resources: SceneRenderResources = .shared) async throws -> AgentPinnedImage {
    guard annotation.fragment.isValid else { throw SceneRenderError.resourceLimit }
    let fragment = annotation.fragment, size = CGSize(width: annotation.fragment.width, height: annotation.fragment.height)
    let scale = min(2, 4096 / size.width, 4096 / size.height, sqrt(4_000_000 / (size.width * size.height)))
    let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
    guard fragment.isValid, width * height <= 4_000_000,
      let reservation = resources.reserveRaster(pixelWidth: width, pixelHeight: height) else { throw SceneRenderError.resourceLimit }
    defer { reservation.release() }
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: ((width * 4 + 63) / 64) * 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.setFillColor(UIColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
    let storage = NSTextStorage(string: fragment.text, attributes: [.font: UIFont.monospacedSystemFont(ofSize: fragment.fontSize, weight: .regular), .foregroundColor: UIColor.black])
    let manager = NSLayoutManager(), container = NSTextContainer(size: .init(width: max(1, fragment.width - 40), height: .greatestFiniteMagnitude))
    manager.addTextContainer(container); storage.addLayoutManager(manager); manager.ensureLayout(for: container)
    let range = manager.glyphRange(for: container), firstY = manager.boundingRect(forGlyphRange: range, in: container).minY
    UIGraphicsPushContext(context)
    manager.drawGlyphs(forGlyphRange: range, at: .init(x: 16, y: -firstY))
    UIGraphicsPopContext()
    guard let image = context.makeImage() else { throw SceneRenderError.snapshotPending("code_text") }
    let canvas = try await SceneRasterCompositor.create(size: size, scale: scale, resources: resources)
    let frame = CGRect(origin: .zero, size: size)
    try await canvas.drawImage(image, in: frame)
    try await canvas.drawInk(surface: .codeFragment(fragment.id), journal: annotation.ink, camera: nil, size: size, in: frame)
    let png = try await canvas.finishPNG()
    return try .init(referenceID: reference.id, sourceRevision: reference.revision, region: fragment.region,
      worldOrigin: nil, pageIndex: nil, pixelWidth: width, pixelHeight: height, pixelsPerPoint: scale,
      png: png, sha256: NotebookFileVersion.hash(png))
  }
}
